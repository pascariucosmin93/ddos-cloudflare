# Nginx IP Monitoring — Documentație

## Arhitectura

```
Internet → Cloudflare Tunnel → nginx (cv/gaz) → logs JSON
                                                      ↓
                                                 Alloy (DaemonSet)
                                                      ↓
                                                 Loki (10.90.90.32:3100)
                                                      ↓
                                                 Grafana (10.90.90.101:8087)
```

---

## Componente

### 1. Aplicații nginx

Deploymente nginx în namespace-urile `cv` și `gaz` (ex: `cv-website`).

**Log format JSON** configurat în `nginx.conf`:
```nginx
map $http_cf_connecting_ip $real_ip {
    ""      $remote_addr;       # fallback dacă nu vine prin Cloudflare
    default $http_cf_connecting_ip;
}

log_format json_cf escape=json
    '{"time":"$time_iso8601",'
    '"ip":"$real_ip",'           # IP-ul real (CF sau direct)
    '"cf_ip":"$http_cf_connecting_ip",'
    '"country":"$http_cf_ipcountry",'
    '"method":"$request_method",'
    '"path":"$request_uri",'
    '"status":$status,'
    '"ua":"$http_user_agent"}';
```

Câmpul `ip`:
- Prin **Cloudflare Tunnel** → IP-ul real al clientului (din `CF-Connecting-IP`)
- **Direct** (fără CF) → `$remote_addr` (IP-ul conectat)

---

### 2. Cloudflare Tunnel

Tunelul existent în namespace `cloudflare` (deployment `cloudflared`) expune aplicațiile public.

---

### 3. Grafana Alloy

**ConfigMap:** `monitoring/alloy` (config.alloy)

Colectează log-urile din **toate** podurile din cluster și le trimite la Loki.

**Pipeline:**
```
loki.source.kubernetes → loki.process (JSON parse) → loki.write → Loki
loki.source.file (hubble) ─────────────────────────────────────→ Loki
```

---

### 4. CiliumNetworkPolicy — Alloy Egress

**Resursă:** `monitoring/alloy-egress-policy`

Permite Alloy să trimită log-uri la Loki (`10.90.90.32:3100`).

---

### 5. Grafana Dashboard

**URL:** `http://10.90.90.101:8087/d/fe273626-9df0-47d3-9398-130cd2e6a1b8/nginx-ip-monitor`

**Paneluri:**
| Panel | Tip | Query |
|-------|-----|-------|
| Log stream live | Logs | `{namespace=~"cv\|gaz"} \| json \| ip != ""` |
| Top IP-uri | Bar chart | `topk(10, sum by (ip) (...))` |
| Top Țări | Pie chart | `sum by (country) (...)` |
| Requesturi în timp | Timeseries | `sum by (namespace) (count_over_time(...))` |

Auto-refresh: 10s.

---

## Queries utile în Grafana Explore (Loki)

```logql
# Toate requesturile cu IP real
{namespace=~"cv|gaz"} | json | ip != ""

# Formatat simplu
{namespace=~"cv|gaz"} | json | line_format "{{.ip}} [{{.country}}] {{.status}} {{.path}}"

# Top 10 IP-uri (ultimele 24h)
topk(10, sum by (ip) (count_over_time({namespace=~"cv|gaz"} | json | ip != "" [24h])))

# Filtrare după IP specific
{namespace=~"cv|gaz"} | json | ip = "1.2.3.4"

# Requesturi per țară
sum by (country) (count_over_time({namespace=~"cv|gaz"} | json | country != "" [1h]))
```

---

## Acces cluster

```bash
ssh root@10.90.90.9       # router/jump host
ssh devops@192.168.70.20  # k8s control plane node
```

Sau într-un singur pas:
```bash
ssh -J root@10.90.90.9 devops@192.168.70.20 "kubectl get nodes"
```
