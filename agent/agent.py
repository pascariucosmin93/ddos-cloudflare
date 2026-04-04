#!/usr/bin/env python3
"""
DDoS Protection Agent
- Citeste request counts din Loki
- Blocheaza IP-uri via CiliumClusterwideNetworkPolicy
- Deblocheaza automat dupa TTL
"""
import ipaddress
import logging
import os
import threading
import time
from collections import deque
from datetime import datetime, timedelta
from typing import Any

import requests
from flask import Flask, jsonify, request as flask_request
from kubernetes import client, config as k8s_config
from kubernetes.client.rest import ApiException

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [AGENT] %(levelname)s %(message)s'
)
log = logging.getLogger(__name__)
app = Flask(__name__)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
LOKI_URL = os.getenv('LOKI_URL', 'http://10.90.90.32:3100')
LOKI_NAMESPACES = os.getenv('LOKI_NAMESPACES', '.+')
THRESHOLD_RPM = int(os.getenv('THRESHOLD_RPM', '100'))
BLOCK_TTL = int(os.getenv('BLOCK_TTL_SECONDS', '300'))
POLL_INTERVAL = int(os.getenv('POLL_INTERVAL_SECONDS', '30'))
NODE_NAME = os.getenv('NODE_NAME', 'unknown')
POLICY_NAME = os.getenv('POLICY_NAME', 'ddos-blocklist')
BLOCK_MODE = os.getenv('BLOCK_MODE', 'cloudflare').strip().lower()
HTTP_TIMEOUT = int(os.getenv('HTTP_TIMEOUT_SECONDS', '10'))

CF_API_BASE = os.getenv('CF_API_BASE', 'https://api.cloudflare.com/client/v4').rstrip('/')
CF_API_TOKEN = os.getenv('CF_API_TOKEN', '')
CF_ACCOUNT_ID = os.getenv('CF_ACCOUNT_ID', '')
CF_LIST_ID = os.getenv('CF_LIST_ID', '')
CF_LIST_NAME = os.getenv('CF_LIST_NAME', 'ddos_blocklist').strip()
CF_SYNC_ON_START = os.getenv('CF_SYNC_ON_START', 'true').strip().lower() in ('1', 'true', 'yes')

TRUSTED_RAW = [v.strip() for v in os.getenv('TRUSTED_CIDRS', '').split(',') if v.strip()]
trusted_networks = []
for v in TRUSTED_RAW:
    try:
        trusted_networks.append(ipaddress.ip_network(v if '/' in v else f'{v}/32', strict=False))
    except ValueError:
        log.warning(f'Invalid TRUSTED_CIDRS entry: {v}')

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
blocked_ips: dict[str, datetime] = {}   # ip -> expiry
cf_item_ids: dict[str, str] = {}        # ip -> cloudflare list item id
event_log = deque(maxlen=500)
last_scan: dict[str, int] = {}
last_scan_at: datetime | None = None
state_lock = threading.Lock()

# ---------------------------------------------------------------------------
# Kubernetes / Cilium
# ---------------------------------------------------------------------------
CILIUM_GROUP = 'cilium.io'
CILIUM_VERSION = 'v2'
CILIUM_PLURAL = 'ciliumclusterwidenetworkpolicies'
custom_api = None


def cilium_enabled() -> bool:
    return BLOCK_MODE in ('cilium', 'both')


def cloudflare_enabled() -> bool:
    return BLOCK_MODE in ('cloudflare', 'both')


if cilium_enabled():
    try:
        k8s_config.load_incluster_config()
    except Exception:
        k8s_config.load_kube_config()
    custom_api = client.CustomObjectsApi()


def build_policy(blocked: list[str]) -> dict:
    """Construieste CiliumClusterwideNetworkPolicy cu deny pe IP-urile blocate.
    Se aplica doar pe namespace-urile monitorizate (LOKI_NAMESPACES).
    """
    if not blocked:
        cidr_set = [{'cidr': '0.0.0.0/32'}]  # dummy — nu blocheaza nimic real
    else:
        cidr_set = [{'cidr': f'{ip}/32'} for ip in blocked]

    # Selecteaza endpoint-urile din namespace-urile monitorizate
    namespaces = [ns.strip() for ns in LOKI_NAMESPACES.split('|') if ns.strip()]
    return {
        'apiVersion': f'{CILIUM_GROUP}/{CILIUM_VERSION}',
        'kind': 'CiliumClusterwideNetworkPolicy',
        'metadata': {'name': POLICY_NAME},
        'spec': {
            'description': 'DDoS auto-blocklist — managed by ddos-agent',
            'endpointSelector': {
                'matchExpressions': [{
                    'key': 'io.kubernetes.pod.namespace',
                    'operator': 'In',
                    'values': namespaces,
                }]
            },
            'ingressDeny': [
                {'fromCIDRSet': cidr_set}
            ],
        }
    }


def apply_cilium_policy(blocked_list: list[str]) -> bool:
    """Creeaza sau updateaza policy-ul Cilium cu lista curenta de IP-uri blocate."""
    if not cilium_enabled():
        return True

    policy = build_policy(blocked_list)
    try:
        custom_api.get_cluster_custom_object(CILIUM_GROUP, CILIUM_VERSION, CILIUM_PLURAL, POLICY_NAME)
        custom_api.replace_cluster_custom_object(
            CILIUM_GROUP, CILIUM_VERSION, CILIUM_PLURAL, POLICY_NAME, policy
        )
        log.info(f'Cilium policy updated — {len(blocked_list)} IP(s) blocked')
        return True
    except ApiException as e:
        if e.status == 404:
            custom_api.create_cluster_custom_object(
                CILIUM_GROUP, CILIUM_VERSION, CILIUM_PLURAL, policy
            )
            log.info(f'Cilium policy created — {len(blocked_list)} IP(s) blocked')
            return True
        else:
            log.error(f'Cilium API error: {e}')
            return False


def delete_cilium_policy() -> bool:
    """Sterge policy-ul cand nu mai sunt IP-uri blocate."""
    if not cilium_enabled():
        return True

    try:
        custom_api.delete_cluster_custom_object(
            CILIUM_GROUP, CILIUM_VERSION, CILIUM_PLURAL, POLICY_NAME
        )
        log.info('Cilium policy deleted — no more blocked IPs')
        return True
    except ApiException as e:
        if e.status != 404:
            log.error(f'Cilium delete error: {e}')
            return False
        return True


# ---------------------------------------------------------------------------
# Cloudflare
# ---------------------------------------------------------------------------
def cloudflare_ready() -> bool:
    return cloudflare_enabled() and bool(CF_API_TOKEN and CF_ACCOUNT_ID)


def cf_headers() -> dict[str, str]:
    return {
        'Authorization': f'Bearer {CF_API_TOKEN}',
        'Content-Type': 'application/json',
    }


def cf_request(method: str, path: str, **kwargs) -> dict[str, Any] | None:
    if not cloudflare_ready():
        return None
    try:
        resp = requests.request(
            method,
            f'{CF_API_BASE}{path}',
            headers=cf_headers(),
            timeout=HTTP_TIMEOUT,
            **kwargs,
        )
        resp.raise_for_status()
        data = resp.json()
        if not data.get('success', False):
            log.error(f'Cloudflare API error on {method} {path}: {data.get("errors")}')
            return None
        return data
    except Exception as exc:
        log.error(f'Cloudflare request failed on {method} {path}: {exc}')
        return None


def cf_resolve_list_id() -> str | None:
    global CF_LIST_ID
    if CF_LIST_ID:
        try:
            resp = requests.get(
                f'{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/rules/lists/{CF_LIST_ID}',
                headers=cf_headers(),
                timeout=HTTP_TIMEOUT,
            )
            if resp.status_code == 404:
                log.warning(
                    'Configured CF_LIST_ID not found via API; '
                    'falling back to CF_LIST_NAME discovery'
                )
                CF_LIST_ID = ''
            else:
                resp.raise_for_status()
                payload = resp.json()
                if payload.get('success', False):
                    return CF_LIST_ID
                log.error(
                    'Cloudflare list id validation failed: '
                    f'{payload.get("errors")}'
                )
        except Exception as exc:
            log.error(f'Cloudflare list id validation failed: {exc}')
            return None
    if not CF_LIST_NAME:
        return None

    data = cf_request('GET', f'/accounts/{CF_ACCOUNT_ID}/rules/lists')
    if not data:
        return None
    for item in data.get('result', []):
        if item.get('name') == CF_LIST_NAME:
            CF_LIST_ID = item.get('id', '')
            return CF_LIST_ID
    log.error(f'Cloudflare list not found: {CF_LIST_NAME}')
    return None


def cf_fetch_items() -> dict[str, str]:
    list_id = cf_resolve_list_id()
    if not list_id:
        return {}

    data = cf_request('GET', f'/accounts/{CF_ACCOUNT_ID}/rules/lists/{list_id}/items')
    if not data:
        return {}

    result: dict[str, str] = {}
    for item in data.get('result', []):
        ip = item.get('ip')
        item_id = item.get('id')
        if ip and item_id:
            result[ip] = item_id
    return result


def cf_add_ip(ip: str, reason: str) -> bool:
    list_id = cf_resolve_list_id()
    if not list_id:
        return False

    data = cf_request(
        'POST',
        f'/accounts/{CF_ACCOUNT_ID}/rules/lists/{list_id}/items',
        json=[{
            'ip': ip,
            'comment': f'ddos-agent:{reason}:{datetime.utcnow().isoformat()}',
        }],
    )
    if not data:
        return False

    refreshed = cf_fetch_items()
    item_id = refreshed.get(ip)
    if item_id:
        cf_item_ids[ip] = item_id
        return True
    log.error(f'Cloudflare add succeeded but item id missing for ip={ip}')
    return False


def cf_remove_ip(ip: str) -> bool:
    list_id = cf_resolve_list_id()
    if not list_id:
        return False

    item_id = cf_item_ids.get(ip)
    if not item_id:
        refreshed = cf_fetch_items()
        item_id = refreshed.get(ip)
        if not item_id:
            return True
        cf_item_ids.update(refreshed)

    data = cf_request(
        'DELETE',
        f'/accounts/{CF_ACCOUNT_ID}/rules/lists/{list_id}/items',
        json={'items': [{'id': item_id}]},
    )
    if not data:
        return False
    cf_item_ids.pop(ip, None)
    return True


# ---------------------------------------------------------------------------
# Loki
# ---------------------------------------------------------------------------
def query_loki() -> dict[str, int]:
    """Returneaza {ip: request_count} pentru ultimul minut."""
    query = (
        f'sum by (ip) ('
        f'count_over_time({{'
        f'namespace=~"{LOKI_NAMESPACES}"'
        f'}} | json | __error__="" | ip != "" [1m])'
        f')'
    )
    try:
        resp = requests.get(
            f'{LOKI_URL}/loki/api/v1/query',
            params={'query': query},
            timeout=10,
        )
        resp.raise_for_status()
        result = {}
        for series in resp.json().get('data', {}).get('result', []):
            ip = series.get('metric', {}).get('ip', '')
            if ip:
                result[ip] = int(float(series['value'][1]))
        return result
    except Exception as e:
        log.warning(f'Loki query failed: {e}')
        return {}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def is_trusted(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
        return any(addr in net for net in trusted_networks)
    except ValueError:
        return True


def block_ip(ip: str, reason: str, rpm: int | None = None) -> bool:
    now = datetime.utcnow()
    with state_lock:
        if ip in blocked_ips:
            return True
        blocked_ips[ip] = now + timedelta(seconds=BLOCK_TTL)

    cf_ok = True
    if cloudflare_enabled():
        if cloudflare_ready():
            cf_ok = cf_add_ip(ip, reason)
        else:
            cf_ok = False
            log.error('Cloudflare mode enabled but CF_API_TOKEN/CF_ACCOUNT_ID missing')

    if cloudflare_enabled() and not cf_ok:
        with state_lock:
            blocked_ips.pop(ip, None)
            event_log.append({
                'time': now.isoformat(),
                'action': f'{reason}_failed',
                'ip': ip,
                'rpm': rpm,
                'cloudflare_synced': False,
            })
        return False

    with state_lock:
        if cilium_enabled():
            if blocked_ips:
                apply_cilium_policy(list(blocked_ips.keys()))
            else:
                delete_cilium_policy()
        event_log.append({
            'time': now.isoformat(),
            'action': reason,
            'ip': ip,
            'rpm': rpm,
            'cloudflare_synced': cf_ok if cloudflare_enabled() else None,
        })
    return cf_ok or not cloudflare_enabled()


def unblock_ip(ip: str, reason: str) -> bool:
    now = datetime.utcnow()
    previous_expiry: datetime | None = None
    with state_lock:
        previous_expiry = blocked_ips.pop(ip, None)
        if cilium_enabled():
            if blocked_ips:
                apply_cilium_policy(list(blocked_ips.keys()))
            else:
                delete_cilium_policy()

    cf_ok = True
    if cloudflare_enabled():
        if cloudflare_ready():
            cf_ok = cf_remove_ip(ip)
        else:
            cf_ok = False

    if cloudflare_enabled() and not cf_ok and previous_expiry:
        with state_lock:
            blocked_ips[ip] = previous_expiry
            if cilium_enabled():
                apply_cilium_policy(list(blocked_ips.keys()))
        return False

    if previous_expiry:
        with state_lock:
            event_log.append({
                'time': now.isoformat(),
                'action': reason,
                'ip': ip,
                'cloudflare_synced': cf_ok if cloudflare_enabled() else None,
            })
    return cf_ok or not cloudflare_enabled()


# ---------------------------------------------------------------------------
# Monitor loop
# ---------------------------------------------------------------------------
def monitor_loop():
    global last_scan, last_scan_at

    while True:
        now = datetime.utcnow()
        counts = query_loki()

        with state_lock:
            last_scan = counts.copy()
            last_scan_at = now

            to_block = [
                (ip, rpm) for ip, rpm in counts.items()
                if not is_trusted(ip) and rpm >= THRESHOLD_RPM and ip not in blocked_ips
            ]
            expired = [ip for ip, exp in blocked_ips.items() if now >= exp]

        for ip, rpm in to_block:
            log.warning(f'ATTACK detected: {ip} — {rpm} req/min')
            block_ip(ip, reason='block', rpm=rpm)

        for ip in expired:
            if unblock_ip(ip, reason='unblock_ttl'):
                log.info(f'UNBLOCKED {ip} (TTL expired)')
            else:
                with state_lock:
                    blocked_ips[ip] = datetime.utcnow() + timedelta(seconds=60)
                    log.warning(f'Unblock retry scheduled for {ip} in 60s')

        time.sleep(POLL_INTERVAL)


# ---------------------------------------------------------------------------
# Web UI
# ---------------------------------------------------------------------------
@app.route('/')
def ui():
    return '''<!DOCTYPE html>
<html lang="ro">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DDoS Protection</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: monospace; background: #0d1117; color: #c9d1d9; padding: 20px; }
  h1 { color: #58a6ff; margin-bottom: 20px; font-size: 20px; }
  h2 { color: #8b949e; font-size: 13px; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 10px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; margin-bottom: 24px; }
  .card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 16px; }
  .stat-value { font-size: 32px; font-weight: bold; color: #58a6ff; }
  .stat-label { font-size: 12px; color: #8b949e; margin-top: 4px; }
  .stat-value.red { color: #f85149; }
  .stat-value.green { color: #3fb950; }
  table { width: 100%; border-collapse: collapse; }
  th { background: #21262d; color: #8b949e; text-align: left; padding: 8px 12px; font-size: 12px; }
  td { padding: 8px 12px; border-bottom: 1px solid #21262d; font-size: 13px; }
  tr:hover td { background: #161b22; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 11px; font-weight: bold; }
  .badge-red { background: #f8514926; color: #f85149; }
  .badge-green { background: #3fb95026; color: #3fb950; }
  .badge-yellow { background: #e3b34126; color: #e3b341; }
  .bar { height: 6px; background: #21262d; border-radius: 3px; margin-top: 4px; }
  .bar-fill { height: 100%; background: #58a6ff; border-radius: 3px; transition: width .3s; }
  .bar-fill.danger { background: #f85149; }
  .section { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 16px; margin-bottom: 16px; }
  .form-row { display: flex; gap: 8px; margin-top: 12px; }
  input[type=text] { flex: 1; background: #0d1117; border: 1px solid #30363d; border-radius: 6px;
    color: #c9d1d9; padding: 8px 12px; font-family: monospace; font-size: 13px; }
  input[type=text]:focus { outline: none; border-color: #58a6ff; }
  button { padding: 8px 16px; border: none; border-radius: 6px; font-family: monospace;
    font-size: 13px; cursor: pointer; font-weight: bold; }
  .btn-block { background: #f85149; color: white; }
  .btn-block:hover { background: #da3633; }
  .btn-unblock { background: #3fb950; color: #0d1117; }
  .btn-unblock:hover { background: #2ea043; }
  .event { padding: 6px 0; border-bottom: 1px solid #21262d; font-size: 12px; color: #8b949e; }
  .event .ip { color: #58a6ff; }
  .event .block { color: #f85149; }
  .event .unblock { color: #3fb950; }
  .pulse { display: inline-block; width: 8px; height: 8px; border-radius: 50%;
    background: #3fb950; margin-right: 6px; animation: pulse 2s infinite; }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.3} }
  .refresh-info { font-size: 11px; color: #8b949e; margin-bottom: 16px; }
</style>
</head>
<body>
<h1><span class="pulse"></span>DDoS Protection Dashboard</h1>
<div class="refresh-info" id="refresh-info">Se actualizeaza...</div>

<div class="grid" id="stats"></div>

<div class="grid" style="grid-template-columns: 1fr 1fr">
  <div class="section">
    <h2>Top IP-uri (req/min)</h2>
    <table><thead><tr><th>IP</th><th>Req/min</th><th>Status</th></tr></thead>
    <tbody id="top-table"></tbody></table>
  </div>
  <div class="section">
    <h2>IP-uri blocate</h2>
    <table><thead><tr><th>IP</th><th>Expira in</th><th></th></tr></thead>
    <tbody id="blocked-table"></tbody></table>
  </div>
</div>

<div class="section">
  <h2>Control manual</h2>
  <div class="form-row">
    <input type="text" id="ip-input" placeholder="IP (ex: 1.2.3.4)">
    <button class="btn-block" onclick="manualBlock()">Blocheaza</button>
    <button class="btn-unblock" onclick="manualUnblock()">Deblocheaza</button>
  </div>
  <div id="action-msg" style="font-size:12px;margin-top:8px;color:#8b949e"></div>
</div>

<div class="section">
  <h2>Evenimente recente</h2>
  <div id="events"></div>
</div>

<script>
async function api(path) {
  const r = await fetch(path);
  return r.json();
}

function fmt(seconds) {
  if (seconds <= 0) return 'expirat';
  const m = Math.floor(seconds / 60), s = seconds % 60;
  return m > 0 ? `${m}m ${s}s` : `${s}s`;
}

async function refresh() {
  const [status, top, blocked, events] = await Promise.all([
    api('/status'), api('/top?limit=15'), api('/blocked'), api('/events?limit=30')
  ]);

  // Stats
  document.getElementById('stats').innerHTML = `
    <div class="card"><div class="stat-value ${status.blocked_count > 0 ? 'red' : 'green'}">
      ${status.blocked_count}</div><div class="stat-label">IP-uri blocate</div></div>
    <div class="card"><div class="stat-value">${status.tracked_ips}</div>
      <div class="stat-label">IP-uri monitorizate</div></div>
    <div class="card"><div class="stat-value">${status.threshold_rpm}</div>
      <div class="stat-label">Prag (req/min)</div></div>
    <div class="card"><div class="stat-value">${status.block_ttl_seconds}s</div>
      <div class="stat-label">Block TTL</div></div>
  `;

  // Top IPs
  const maxRpm = Math.max(...top.items.map(i => i.rpm), 1);
  document.getElementById('top-table').innerHTML = top.items.map(i => {
    const pct = Math.min(100, (i.rpm / maxRpm) * 100);
    const danger = i.rpm >= status.threshold_rpm;
    const badge = i.blocked
      ? '<span class="badge badge-red">BLOCAT</span>'
      : i.trusted
        ? '<span class="badge badge-green">trusted</span>'
        : danger
          ? '<span class="badge badge-yellow">ATAC</span>'
          : '';
    return `<tr>
      <td>${i.ip}</td>
      <td>${i.rpm}<div class="bar"><div class="bar-fill ${danger?'danger':''}" style="width:${pct}%"></div></div></td>
      <td>${badge}</td>
    </tr>`;
  }).join('');

  // Blocked
  const now = Date.now() / 1000;
  document.getElementById('blocked-table').innerHTML = Object.keys(blocked).length === 0
    ? '<tr><td colspan="3" style="color:#8b949e;text-align:center">Niciun IP blocat</td></tr>'
    : Object.entries(blocked).map(([ip, info]) => {
        const rem = Math.max(0, Math.round(info.remaining_seconds));
        return `<tr>
          <td><span class="badge badge-red">${ip}</span></td>
          <td>${fmt(rem)}</td>
          <td><button class="btn-unblock" style="padding:4px 10px;font-size:11px"
            onclick="unblockIP('${ip}')">Deblocheaza</button></td>
        </tr>`;
      }).join('');

  // Events
  document.getElementById('events').innerHTML = events.items.reverse().map(e => {
    const cls = e.action.includes('block') && !e.action.includes('un') ? 'block' : 'unblock';
    const extra = e.rpm ? ` — ${e.rpm} req/min` : '';
    return `<div class="event">${e.time} <span class="${cls}">[${e.action.toUpperCase()}]</span>
      <span class="ip">${e.ip}</span>${extra}</div>`;
  }).join('') || '<div style="color:#8b949e;font-size:12px">Niciun eveniment</div>';

  document.getElementById('refresh-info').textContent =
    `Ultima actualizare: ${new Date().toLocaleTimeString()} — urmatoarea in 15s`;
}

async function manualBlock() {
  const ip = document.getElementById('ip-input').value.trim();
  if (!ip) return;
  const r = await fetch('/block', {
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body: JSON.stringify({ip})
  });
  const d = await r.json();
  document.getElementById('action-msg').textContent =
    d.blocked ? `Blocat: ${d.blocked}` : (d.error || 'Eroare');
  refresh();
}

async function manualUnblock() {
  const ip = document.getElementById('ip-input').value.trim();
  if (!ip) return;
  unblockIP(ip);
}

async function unblockIP(ip) {
  const r = await fetch('/unblock', {
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body: JSON.stringify({ip})
  });
  const d = await r.json();
  document.getElementById('action-msg').textContent =
    d.unblocked ? `Deblocat: ${d.unblocked}` : (d.error || 'Eroare');
  document.getElementById('ip-input').value = ip;
  refresh();
}

refresh();
setInterval(refresh, 15000);
</script>
</body>
</html>'''


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------
@app.route('/health')
def health():
    return jsonify({'status': 'ok', 'node': NODE_NAME})


@app.route('/status')
def status():
    with state_lock:
        return jsonify({
            'node': NODE_NAME,
            'threshold_rpm': THRESHOLD_RPM,
            'block_ttl_seconds': BLOCK_TTL,
            'poll_interval_seconds': POLL_INTERVAL,
            'blocked_count': len(blocked_ips),
            'tracked_ips': len(last_scan),
            'last_scan_at': last_scan_at.isoformat() if last_scan_at else None,
            'policy_name': POLICY_NAME,
            'block_mode': BLOCK_MODE,
            'cloudflare_enabled': cloudflare_enabled(),
            'cloudflare_ready': cloudflare_ready(),
            'cloudflare_list_id': CF_LIST_ID,
        })


@app.route('/blocked')
def get_blocked():
    with state_lock:
        return jsonify({
            ip: {
                'expires': exp.isoformat(),
                'remaining_seconds': max(0, int((exp - datetime.utcnow()).total_seconds())),
                'cloudflare_synced': ip in cf_item_ids if cloudflare_enabled() else None,
            }
            for ip, exp in blocked_ips.items()
        })


@app.route('/top')
def top():
    limit = int(flask_request.args.get('limit', '20'))
    with state_lock:
        items = sorted(last_scan.items(), key=lambda x: x[1], reverse=True)[:limit]
        return jsonify({
            'node': NODE_NAME,
            'last_scan_at': last_scan_at.isoformat() if last_scan_at else None,
            'threshold_rpm': THRESHOLD_RPM,
            'items': [
                {
                    'ip': ip,
                    'rpm': rpm,
                    'trusted': is_trusted(ip),
                    'blocked': ip in blocked_ips,
                    'expires': blocked_ips[ip].isoformat() if ip in blocked_ips else None,
                }
                for ip, rpm in items
            ]
        })


@app.route('/events')
def events():
    limit = int(flask_request.args.get('limit', '100'))
    with state_lock:
        return jsonify({'node': NODE_NAME, 'items': list(event_log)[-limit:]})


@app.route('/block', methods=['POST'])
def manual_block():
    data = flask_request.get_json() or {}
    ip = data.get('ip', '').strip()
    if not ip:
        return jsonify({'error': 'ip required'}), 400
    if is_trusted(ip):
        return jsonify({'error': 'IP is trusted'}), 403
    ok = block_ip(ip, reason='manual_block', rpm=None)
    if not ok:
        return jsonify({'error': 'block failed for selected provider'}), 502
    return jsonify({'blocked': ip})


@app.route('/unblock', methods=['POST'])
def manual_unblock():
    data = flask_request.get_json() or {}
    ip = data.get('ip', '').strip()
    if not ip:
        return jsonify({'error': 'ip required'}), 400
    ok = unblock_ip(ip, reason='manual_unblock')
    if not ok:
        return jsonify({'error': 'unblock failed for selected provider'}), 502
    return jsonify({'unblocked': ip})


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == '__main__':
    log.info(f'Starting DDoS agent — node={NODE_NAME}')
    log.info(f'Loki={LOKI_URL}, namespaces={LOKI_NAMESPACES}')
    log.info(f'Threshold={THRESHOLD_RPM} rpm, TTL={BLOCK_TTL}s, poll={POLL_INTERVAL}s')
    log.info(f'Block mode={BLOCK_MODE}')
    if cloudflare_enabled():
        log.info(f'Cloudflare enabled; account={CF_ACCOUNT_ID or "missing"}, list_id={CF_LIST_ID or "auto"}')
        if CF_SYNC_ON_START and cloudflare_ready():
            cf_items = cf_fetch_items()
            cf_item_ids.update(cf_items)
            log.info(f'Cloudflare list synced on start: {len(cf_items)} item(s)')

    threading.Thread(target=monitor_loop, daemon=True).start()
    app.run(host='0.0.0.0', port=8080)
