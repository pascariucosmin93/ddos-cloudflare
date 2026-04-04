#!/usr/bin/env python3
import os
import time
import json
import logging
import threading
import requests
from collections import defaultdict
from datetime import datetime, timedelta
from flask import Flask, jsonify, request

import kubernetes
from kubernetes import client as k8s_client, config as k8s_config
from kubernetes.client.rest import ApiException

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [CTRL] %(levelname)s %(message)s'
)
log = logging.getLogger(__name__)

app = Flask(__name__)

# Config from env
NAMESPACE = os.getenv('NAMESPACE', 'ddos-protection')
AGENT_PORT = int(os.getenv('AGENT_PORT', '8080'))
SYNC_INTERVAL = int(os.getenv('SYNC_INTERVAL_SECONDS', '15'))
GLOBAL_BLOCK_THRESHOLD = int(os.getenv('GLOBAL_BLOCK_THRESHOLD', '2'))  # blocked on N nodes → global block
BLOCK_TTL = int(os.getenv('BLOCK_TTL_SECONDS', '600'))
WHITELIST = set(os.getenv('WHITELIST_IPS', '').split(',')) - {''}

# State
global_blocks: dict[str, datetime] = {}
node_reports: dict[str, dict] = {}
state_lock = threading.Lock()


def load_k8s_config():
    try:
        k8s_config.load_incluster_config()
    except Exception:
        k8s_config.load_kube_config()


def get_agent_pods() -> list[str]:
    """Get IPs of all ddos-agent pods."""
    load_k8s_config()
    v1 = k8s_client.CoreV1Api()
    pods = v1.list_namespaced_pod(
        namespace=NAMESPACE,
        label_selector='app=ddos-agent'
    )
    return [
        pod.status.pod_ip
        for pod in pods.items
        if pod.status.pod_ip and pod.status.phase == 'Running'
    ]


def apply_cilium_network_policy(ip: str):
    """Create a CiliumNetworkPolicy to block IP cluster-wide."""
    load_k8s_config()
    api = k8s_client.CustomObjectsApi()

    policy_name = f"ddos-block-{ip.replace('.', '-')}"
    policy = {
        'apiVersion': 'cilium.io/v2',
        'kind': 'CiliumClusterwideNetworkPolicy',
        'metadata': {'name': policy_name},
        'spec': {
            'description': f'DDoS block for {ip}',
            'ingress': [{'fromCIDR': [f'{ip}/32']}],
            'endpointSelector': {}
        }
    }

    try:
        api.create_cluster_custom_object(
            group='cilium.io',
            version='v2',
            plural='ciliumclusterwidenetworkpolicies',
            body=policy
        )
        log.warning(f"GLOBAL BLOCK applied for {ip}")
    except ApiException as e:
        if e.status == 409:
            log.debug(f"Policy already exists for {ip}")
        else:
            log.error(f"Failed to create CiliumNetworkPolicy for {ip}: {e}")


def delete_cilium_network_policy(ip: str):
    """Remove the CiliumNetworkPolicy block for IP."""
    load_k8s_config()
    api = k8s_client.CustomObjectsApi()
    policy_name = f"ddos-block-{ip.replace('.', '-')}"

    try:
        api.delete_cluster_custom_object(
            group='cilium.io',
            version='v2',
            plural='ciliumclusterwidenetworkpolicies',
            name=policy_name
        )
        log.info(f"GLOBAL UNBLOCK for {ip}")
    except ApiException as e:
        if e.status != 404:
            log.error(f"Failed to delete CiliumNetworkPolicy for {ip}: {e}")


def collect_from_agents():
    """Poll all agent pods and aggregate blocked IPs."""
    try:
        agent_ips = get_agent_pods()
    except Exception as e:
        log.error(f"Cannot list agent pods: {e}")
        return

    ip_block_count: dict[str, int] = defaultdict(int)

    for agent_ip in agent_ips:
        url = f'http://{agent_ip}:{AGENT_PORT}/blocked'
        try:
            resp = requests.get(url, timeout=5)
            data = resp.json()
            with state_lock:
                node_reports[agent_ip] = data
            for blocked_ip in data:
                ip_block_count[blocked_ip] += 1
        except Exception as e:
            log.warning(f"Cannot reach agent {agent_ip}: {e}")

    now = datetime.utcnow()

    with state_lock:
        # Apply global block if IP is blocked on >= GLOBAL_BLOCK_THRESHOLD nodes
        for ip, count in ip_block_count.items():
            if ip in WHITELIST:
                continue
            if count >= GLOBAL_BLOCK_THRESHOLD and ip not in global_blocks:
                apply_cilium_network_policy(ip)
                global_blocks[ip] = now + timedelta(seconds=BLOCK_TTL)
                log.warning(f"Global block: {ip} (seen on {count} nodes)")

        # Unblock expired global blocks
        expired = [ip for ip, exp in global_blocks.items() if now >= exp]
        for ip in expired:
            delete_cilium_network_policy(ip)
            del global_blocks[ip]


def sync_loop():
    while True:
        collect_from_agents()
        time.sleep(SYNC_INTERVAL)


@app.route('/health')
def health():
    return jsonify({'status': 'ok'})


@app.route('/status')
def status():
    with state_lock:
        return jsonify({
            'global_blocks': {
                ip: exp.isoformat() for ip, exp in global_blocks.items()
            },
            'node_reports': node_reports,
            'config': {
                'global_block_threshold': GLOBAL_BLOCK_THRESHOLD,
                'block_ttl_seconds': BLOCK_TTL,
                'sync_interval_seconds': SYNC_INTERVAL,
            }
        })


@app.route('/unblock/<ip>', methods=['POST'])
def manual_unblock(ip: str):
    with state_lock:
        if ip in global_blocks:
            delete_cilium_network_policy(ip)
            del global_blocks[ip]
            return jsonify({'status': 'unblocked', 'ip': ip})
    return jsonify({'status': 'not_found', 'ip': ip}), 404


if __name__ == '__main__':
    log.info("Starting DDoS controller")
    t = threading.Thread(target=sync_loop, daemon=True)
    t.start()
    app.run(host='0.0.0.0', port=8080)
