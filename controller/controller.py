#!/usr/bin/env python3
import ipaddress
import logging
import os
import threading
import time
from collections import defaultdict
from datetime import datetime, timedelta

import requests
from flask import Flask, jsonify, request
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
GLOBAL_BLOCK_THRESHOLD = int(os.getenv('GLOBAL_BLOCK_THRESHOLD', '3'))
BLOCK_TTL = int(os.getenv('BLOCK_TTL_SECONDS', '120'))
ENABLE_GLOBAL_BLOCKS = os.getenv('ENABLE_GLOBAL_BLOCKS', 'false').lower() in {'1', 'true', 'yes'}
PROTECTED_NAMESPACES_RAW = os.getenv('PROTECTED_NAMESPACES', 'cv|gaz')
PROTECTED_NAMESPACES = [v.strip() for v in PROTECTED_NAMESPACES_RAW.split('|') if v.strip()]

TRUSTED_CIDRS_RAW = [v.strip() for v in os.getenv('TRUSTED_CIDRS', '').split(',') if v.strip()]
LEGACY_WHITELIST = [v.strip() for v in os.getenv('WHITELIST_IPS', '').split(',') if v.strip()]

# State
global_blocks: dict[str, datetime] = {}
node_reports: dict[str, dict] = {}
state_lock = threading.Lock()

trusted_networks: list[ipaddress._BaseNetwork] = []
for value in TRUSTED_CIDRS_RAW + LEGACY_WHITELIST:
    try:
        if '/' not in value:
            value = f'{value}/32'
        trusted_networks.append(ipaddress.ip_network(value, strict=False))
    except ValueError:
        log.warning(f'Ignoring invalid TRUSTED_CIDRS/WHITELIST_IPS entry: {value}')


def is_trusted_ip(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return True

    for network in trusted_networks:
        if addr in network:
            return True
    return False


def load_k8s_config():
    try:
        k8s_config.load_incluster_config()
    except Exception:
        k8s_config.load_kube_config()


def get_agent_pods() -> list[str]:
    """Get IPs of all ddos-agent pods."""
    load_k8s_config()
    v1 = k8s_client.CoreV1Api()
    pods = v1.list_namespaced_pod(namespace=NAMESPACE, label_selector='app=ddos-agent')
    return [pod.status.pod_ip for pod in pods.items if pod.status.pod_ip and pod.status.phase == 'Running']


def apply_cilium_network_policy(ip: str):
    """Create a deny CiliumClusterwideNetworkPolicy for source IP."""
    load_k8s_config()
    api = k8s_client.CustomObjectsApi()

    policy_name = f'ddos-block-{ip.replace(".", "-")}'
    if not PROTECTED_NAMESPACES:
        log.error('Cannot apply global Cilium policy: PROTECTED_NAMESPACES is empty')
        return

    policy = {
        'apiVersion': 'cilium.io/v2',
        'kind': 'CiliumClusterwideNetworkPolicy',
        'metadata': {
            'name': policy_name,
            'labels': {'app': 'ddos-protection'},
        },
        'spec': {
            'description': f'DDoS deny block for {ip} on protected namespaces',
            'endpointSelector': {
                'matchExpressions': [
                    {
                        'key': 'io.kubernetes.pod.namespace',
                        'operator': 'In',
                        'values': PROTECTED_NAMESPACES,
                    }
                ]
            },
            'ingressDeny': [
                {
                    'fromCIDRSet': [{'cidr': f'{ip}/32'}],
                }
            ],
        },
    }

    try:
        api.create_cluster_custom_object(
            group='cilium.io',
            version='v2',
            plural='ciliumclusterwidenetworkpolicies',
            body=policy,
        )
        log.warning(f'GLOBAL BLOCK applied for {ip}')
    except ApiException as e:
        if e.status == 409:
            log.debug(f'Policy already exists for {ip}')
        else:
            log.error(f'Failed to create Cilium policy for {ip}: {e}')


def delete_cilium_network_policy(ip: str):
    """Remove the Cilium policy block for IP."""
    load_k8s_config()
    api = k8s_client.CustomObjectsApi()
    policy_name = f'ddos-block-{ip.replace(".", "-")}'

    try:
        api.delete_cluster_custom_object(
            group='cilium.io',
            version='v2',
            plural='ciliumclusterwidenetworkpolicies',
            name=policy_name,
        )
        log.info(f'GLOBAL UNBLOCK for {ip}')
    except ApiException as e:
        if e.status != 404:
            log.error(f'Failed to delete Cilium policy for {ip}: {e}')


def collect_from_agents():
    """Poll all agent pods and aggregate blocked IPs."""
    try:
        agent_ips = get_agent_pods()
    except Exception as e:
        log.error(f'Cannot list agent pods: {e}')
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
            log.warning(f'Cannot reach agent {agent_ip}: {e}')

    now = datetime.utcnow()

    with state_lock:
        for ip, count in ip_block_count.items():
            if is_trusted_ip(ip):
                continue
            if count >= GLOBAL_BLOCK_THRESHOLD and ip not in global_blocks:
                if ENABLE_GLOBAL_BLOCKS:
                    apply_cilium_network_policy(ip)
                global_blocks[ip] = now + timedelta(seconds=BLOCK_TTL)
                log.warning(f'Global candidate: {ip} (seen on {count} nodes, enabled={ENABLE_GLOBAL_BLOCKS})')

        expired = [ip for ip, exp in global_blocks.items() if now >= exp]
        for ip in expired:
            if ENABLE_GLOBAL_BLOCKS:
                delete_cilium_network_policy(ip)
            del global_blocks[ip]


def collect_top_sources(limit: int, include_trusted: bool):
    try:
        agent_ips = get_agent_pods()
    except Exception as e:
        return {'error': f'Cannot list agent pods: {e}'}, 500

    aggregated: dict[str, int] = defaultdict(int)
    by_node: dict[str, list] = {}

    for agent_ip in agent_ips:
        url = f'http://{agent_ip}:{AGENT_PORT}/top?limit={limit}&include_trusted={"true" if include_trusted else "false"}'
        try:
            resp = requests.get(url, timeout=5)
            resp.raise_for_status()
            data = resp.json()
            by_node[agent_ip] = data.get('items', [])
            for row in data.get('items', []):
                ip = row.get('ip')
                count = int(row.get('connections', 0))
                if ip:
                    aggregated[ip] += count
        except Exception as e:
            by_node[agent_ip] = [{'error': str(e)}]

    top_cluster = sorted(aggregated.items(), key=lambda item: item[1], reverse=True)[:limit]
    return (
        {
            'cluster_top': [{'ip': ip, 'connections': count, 'trusted': is_trusted_ip(ip)} for ip, count in top_cluster],
            'by_node': by_node,
        },
        200,
    )


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
        return jsonify(
            {
                'global_blocks': {ip: exp.isoformat() for ip, exp in global_blocks.items()},
                'node_reports': node_reports,
                'config': {
                    'global_block_threshold': GLOBAL_BLOCK_THRESHOLD,
                    'block_ttl_seconds': BLOCK_TTL,
                    'sync_interval_seconds': SYNC_INTERVAL,
                    'enable_global_blocks': ENABLE_GLOBAL_BLOCKS,
                    'trusted_cidrs': [str(v) for v in trusted_networks],
                    'protected_namespaces': PROTECTED_NAMESPACES,
                },
            }
        )


@app.route('/traffic')
def traffic():
    limit = int(request.args.get('limit', '20'))
    include_trusted = request.args.get('include_trusted', 'false').lower() in {'1', 'true', 'yes'}
    payload, code = collect_top_sources(limit=limit, include_trusted=include_trusted)
    return jsonify(payload), code


@app.route('/unblock/<ip>', methods=['POST'])
def manual_unblock(ip: str):
    with state_lock:
        if ip in global_blocks:
            if ENABLE_GLOBAL_BLOCKS:
                delete_cilium_network_policy(ip)
            del global_blocks[ip]
            return jsonify({'status': 'unblocked', 'ip': ip})
    return jsonify({'status': 'not_found', 'ip': ip}), 404


if __name__ == '__main__':
    log.info('Starting DDoS controller')
    log.info(
        f'Global blocks enabled={ENABLE_GLOBAL_BLOCKS}, threshold={GLOBAL_BLOCK_THRESHOLD}, '
        f'trusted={ [str(v) for v in trusted_networks] }'
    )
    t = threading.Thread(target=sync_loop, daemon=True)
    t.start()
    app.run(host='0.0.0.0', port=8080)
