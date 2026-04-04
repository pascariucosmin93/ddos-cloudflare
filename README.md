# ddos-protect-k8s

A lightweight, node-level DDoS protection system for Kubernetes. It combines per-node traffic monitoring via `iptables` with cluster-wide enforcement via Cilium network policies.

## How it works

The system has two components: an **Agent** (DaemonSet) running on every node and a **Controller** (Deployment) running as a central aggregator.

```
Internet
   │
   ▼
[ K8s Node ]──────────────────────────────────────────────────
│  Agent (DaemonSet)                                          │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 1. Reads /proc/net/nf_conntrack every 10s            │  │
│  │ 2. Counts connections per source IP                  │  │
│  │ 3. If IP exceeds threshold → iptables DROP (node)    │  │
│  │ 4. Exposes /blocked over HTTP                        │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                         │ polls /blocked every 15s
                         ▼
[ Controller (Deployment) ]
  ┌───────────────────────────────────────────────────────────┐
  │ 5. Aggregates blocked IPs from all agent pods             │
  │ 6. If IP is blocked on >= 2 nodes → CiliumClusterwide     │
  │    NetworkPolicy (blocks IP across entire cluster)        │
  │ 7. Auto-expires blocks after TTL                          │
  └───────────────────────────────────────────────────────────┘
```

### Agent

Runs as a DaemonSet with `hostNetwork: true` and `NET_ADMIN`/`NET_RAW` capabilities so it can read conntrack and manage iptables on the host.

- Reads `/proc/net/nf_conntrack` to count active connections per source IP
- Maintains a sliding time window (default: 60s)
- If any IP exceeds `THRESHOLD_CONNECTIONS` (default: 100) within the window → inserts an `iptables -I INPUT DROP` rule
- Blocks are automatically lifted after `BLOCK_TTL_SECONDS` (default: 10 minutes)
- Whitelisted IPs are never blocked
- Exposes a REST API on port 8080:
  - `GET /health` — liveness probe
  - `GET /status` — current state (blocked IPs, tracked IPs, config)
  - `GET /blocked` — map of `{ ip: expiry_timestamp }`

### Controller

Runs as a single Deployment with in-cluster RBAC to manage Cilium CRDs.

- Polls every agent pod's `/blocked` endpoint every `SYNC_INTERVAL_SECONDS` (default: 15s)
- Counts how many nodes have blocked each IP
- If an IP is blocked on `GLOBAL_BLOCK_THRESHOLD` (default: 2) or more nodes → creates a `CiliumClusterwideNetworkPolicy` to block it at the CNI level across the entire cluster
- Expired global blocks are cleaned up automatically
- Exposes a REST API on port 8080:
  - `GET /health` — liveness probe
  - `GET /status` — global blocks, per-node reports, config
  - `POST /unblock/<ip>` — manually lift a global block

## Configuration

All settings are managed via the `ddos-config` ConfigMap in `k8s/configmap.yaml`:

| Variable | Default | Description |
|---|---|---|
| `THRESHOLD_CONNECTIONS` | `100` | Max connections from one IP within the window |
| `THRESHOLD_WINDOW_SECONDS` | `60` | Sliding window size in seconds |
| `BLOCK_TTL_SECONDS` | `600` | How long an IP stays blocked (10 minutes) |
| `POLL_INTERVAL_SECONDS` | `10` | How often the agent reads conntrack |
| `WHITELIST_IPS` | `` | Comma-separated IPs that are never blocked |
| `GLOBAL_BLOCK_THRESHOLD` | `2` | Nodes that must report a block to trigger a cluster-wide policy |
| `SYNC_INTERVAL_SECONDS` | `15` | How often the controller polls agents |

## Prerequisites

- Kubernetes cluster with **Cilium** as the CNI (required for cluster-wide blocks)
- Nodes must have `nf_conntrack` kernel module loaded
- Container registry accessible from the cluster (GHCR by default in CI)

## Deploy

```bash
# Apply all manifests
make deploy

# Check status
make status

# Stream agent logs
make logs-agent

# Stream controller logs
make logs-controller
```

Or manually:

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/rbac.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/daemonset.yaml
kubectl apply -f k8s/deployment.yaml
```

## CI/CD

Three GitHub Actions workflows are included:

| Workflow | Trigger | Purpose |
|---|---|---|
| `ci.yml` | Every push / PR | Lint (`flake8`) agent and controller, validate K8s manifests |
| `release.yml` | Push to `main` (path-filtered) or manual | Build and push Docker images to GHCR tagged with `short_sha` and `0.0.<run_number>` |
| `promote.yml` | Manual (`workflow_dispatch`) | Re-tag a dev image (e.g. `0.0.42`) as a semver release (e.g. `1.0.0`, `1.0`, `1`, `latest`) |

Images are published to GHCR:
- `ghcr.io/<owner>/ddos-agent`
- `ghcr.io/<owner>/ddos-controller`

No external secrets are needed — `GITHUB_TOKEN` is used automatically for GHCR access.

## Build locally

```bash
make build REGISTRY=ghcr.io/your-username TAG=dev
make push  REGISTRY=ghcr.io/your-username TAG=dev
```
