#!/usr/bin/env python3
import os
import time
import logging
import subprocess
import threading
from collections import defaultdict
from datetime import datetime, timedelta
from flask import Flask, jsonify

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [AGENT] %(levelname)s %(message)s'
)
log = logging.getLogger(__name__)

app = Flask(__name__)

# Config from env
THRESHOLD_CONN = int(os.getenv('THRESHOLD_CONNECTIONS', '100'))
THRESHOLD_WINDOW = int(os.getenv('THRESHOLD_WINDOW_SECONDS', '60'))
BLOCK_TTL = int(os.getenv('BLOCK_TTL_SECONDS', '600'))
WHITELIST = set(os.getenv('WHITELIST_IPS', '').split(',')) - {''}
POLL_INTERVAL = int(os.getenv('POLL_INTERVAL_SECONDS', '10'))
NODE_NAME = os.getenv('NODE_NAME', 'unknown')

# State
blocked_ips: dict[str, datetime] = {}
conn_history: dict[str, list] = defaultdict(list)
state_lock = threading.Lock()


def read_conntrack() -> dict[str, int]:
    """Read /proc/net/nf_conntrack and count connections per source IP."""
    counts: dict[str, int] = defaultdict(int)
    try:
        with open('/proc/net/nf_conntrack', 'r') as f:
            for line in f:
                parts = line.split()
                for part in parts:
                    if part.startswith('src='):
                        ip = part[4:]
                        counts[ip] += 1
                        break
    except Exception as e:
        log.warning(f"Cannot read conntrack: {e}")
    return counts


def block_ip(ip: str):
    """Add iptables DROP rule for IP."""
    try:
        result = subprocess.run(
            ['iptables', '-C', 'INPUT', '-s', ip, '-j', 'DROP'],
            capture_output=True
        )
        if result.returncode != 0:
            subprocess.run(
                ['iptables', '-I', 'INPUT', '1', '-s', ip, '-j', 'DROP'],
                check=True, capture_output=True
            )
            log.warning(f"BLOCKED {ip} on node {NODE_NAME}")
    except Exception as e:
        log.error(f"Failed to block {ip}: {e}")


def unblock_ip(ip: str):
    """Remove iptables DROP rule for IP."""
    try:
        subprocess.run(
            ['iptables', '-D', 'INPUT', '-s', ip, '-j', 'DROP'],
            capture_output=True
        )
        log.info(f"UNBLOCKED {ip} on node {NODE_NAME}")
    except Exception as e:
        log.error(f"Failed to unblock {ip}: {e}")


def monitor_loop():
    """Main monitoring loop."""
    while True:
        now = datetime.utcnow()
        window_start = now - timedelta(seconds=THRESHOLD_WINDOW)

        counts = read_conntrack()

        with state_lock:
            # Update connection history
            for ip, count in counts.items():
                if ip in WHITELIST:
                    continue
                conn_history[ip].append((now, count))
                # Keep only entries within window
                conn_history[ip] = [
                    (t, c) for t, c in conn_history[ip] if t > window_start
                ]

            # Check thresholds
            for ip, history in conn_history.items():
                if not history:
                    continue
                max_conn = max(c for _, c in history)
                if max_conn >= THRESHOLD_CONN and ip not in blocked_ips:
                    block_ip(ip)
                    blocked_ips[ip] = now + timedelta(seconds=BLOCK_TTL)

            # Unblock expired IPs
            expired = [ip for ip, exp in blocked_ips.items() if now >= exp]
            for ip in expired:
                unblock_ip(ip)
                del blocked_ips[ip]
                if ip in conn_history:
                    del conn_history[ip]

        time.sleep(POLL_INTERVAL)


@app.route('/health')
def health():
    return jsonify({'status': 'ok', 'node': NODE_NAME})


@app.route('/status')
def status():
    with state_lock:
        return jsonify({
            'node': NODE_NAME,
            'blocked': {
                ip: exp.isoformat() for ip, exp in blocked_ips.items()
            },
            'tracked_ips': len(conn_history),
            'threshold_connections': THRESHOLD_CONN,
            'block_ttl_seconds': BLOCK_TTL,
        })


@app.route('/blocked')
def get_blocked():
    with state_lock:
        return jsonify({
            ip: exp.isoformat() for ip, exp in blocked_ips.items()
        })


if __name__ == '__main__':
    log.info(f"Starting DDoS agent on node {NODE_NAME}")
    log.info(f"Threshold: {THRESHOLD_CONN} connections/{THRESHOLD_WINDOW}s, TTL: {BLOCK_TTL}s")

    t = threading.Thread(target=monitor_loop, daemon=True)
    t.start()

    app.run(host='0.0.0.0', port=8080)
