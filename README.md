# ddos-protect-k8s

DDoS protection agent for Kubernetes using Loki traffic signals and automatic blocking.

## Current flow

- `ddos-agent` reads request volume from Loki (`count_over_time` grouped by `ip`).
- If an IP exceeds `THRESHOLD_RPM`, it is blocked for `BLOCK_TTL_SECONDS`.
- Blocking provider is controlled by `BLOCK_MODE`:
- `cloudflare`: add/remove IPs in Cloudflare account list (recommended for tunnel traffic).
- `cilium`: manage `CiliumClusterwideNetworkPolicy` deny list.
- `both`: apply both providers.
- Web UI/API exposed on port `8080` for status + manual block/unblock.

## Config

Main config is in `k8s/configmap.yaml` (`ddos-config`).

Required secret for Cloudflare mode is `k8s/cloudflare-secret.example.yaml`.

Important env vars:

- `LOKI_URL`
- `LOKI_NAMESPACES`
- `THRESHOLD_RPM`
- `BLOCK_TTL_SECONDS`
- `POLL_INTERVAL_SECONDS`
- `BLOCK_MODE` (`cloudflare|cilium|both`)
- `CF_API_TOKEN` (Secret)
- `CF_ACCOUNT_ID` (Secret)
- `CF_LIST_ID` (Secret, recommended)
- `TRUSTED_CIDRS`

## Deploy

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/rbac.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/cloudflare-secret.example.yaml
kubectl apply -f k8s/daemonset.yaml
```

## Build and push image

```bash
make docker-build TAG=0.0.8
make docker-push TAG=0.0.8
```

Then update `k8s/daemonset.yaml` image tag and re-apply.

## Quick checks

```bash
kubectl -n ddos-protection get pods -o wide
kubectl -n ddos-protection logs -l app=ddos-agent --tail=100
kubectl -n ddos-protection port-forward ds/ddos-agent 8080:8080
curl -s http://127.0.0.1:8080/status | jq
curl -s "http://127.0.0.1:8080/top?limit=20" | jq
```

## Manual API

```bash
curl -s -X POST http://127.0.0.1:8080/block -H 'Content-Type: application/json' -d '{"ip":"1.2.3.4"}'
curl -s -X POST http://127.0.0.1:8080/unblock -H 'Content-Type: application/json' -d '{"ip":"1.2.3.4"}'
```
