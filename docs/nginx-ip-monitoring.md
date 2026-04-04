# Nginx IP Monitoring — Documentație

## Arhitectura

```
Internet → Cloudflare Tunnel → nginx (app1/app2) → logs JSON
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

**Fișiere:** `k8s/nginx-app1.yaml`, `k8s/nginx-app2.yaml`

Două deploymente nginx (2 replici fiecare) în namespace-urile `app1` și `app2`.

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
    '"ray":"$http_cf_ray",'
    '"method":"$request_method",'
    '"path":"$request_uri",'
    '"status":$status,'
    '"ua":"$http_user_agent"}';
```

Câmpul `ip`:
- Prin **Cloudflare Tunnel** → IP-ul real al clientului (din `CF-Connecting-IP`)
- **Direct** (fără CF) → `$remote_addr` (IP-ul conectat)

---

### 2. Cilium Gateway

**Fișier:** `k8s/nginx-gateway.yaml`

Gateway dedicat în namespace `nginx-demo`, IP: `10.30.10.0`.

| Hostname | Namespace backend |
|----------|------------------|
| `app1.local` | `app1` |
| `app2.local` | `app2` |

Routare hostname-based via `HTTPRoute`.

---

### 3. Cloudflare Tunnel

Tunelul existent în namespace `clouadfare` (deployment `cloudflared`) expune aplicațiile public.

Configurare în Cloudflare Dashboard → Tunnels → Public Hostnames:

| Public Hostname | Service (intern cluster) |
|----------------|--------------------------|
| `app1.cosmin-lab.com` | `http://nginx-app1.app1.svc.cluster.local` |
| `app2.cosmin-lab.com` | `http://nginx-app2.app2.svc.cluster.local` |

> **Important:** Se pointează direct la serviciul ClusterIP, nu la Gateway, pentru că cloudflared rulează în cluster și poate rezolva DNS intern.

---

### 4. Grafana Alloy

**ConfigMap:** `monitoring/alloy` (config.alloy)

Colectează log-urile din **toate** podurile din cluster și le trimite la Loki.

**Modificări față de config-ul original:**
- URL Loki corectat: `10.13.13.30:3100` → `10.90.90.32:3100`
- Adăugat stage `loki.process` cu JSON parsing pentru extragerea câmpurilor `ip` și `country` ca label-uri Loki (util pentru filtrare rapidă în Grafana)

**Pipeline:**
```
loki.source.kubernetes → loki.process (JSON parse) → loki.write → Loki
loki.source.file (hubble) ─────────────────────────────────────→ Loki
```

---

### 5. CiliumNetworkPolicy — Alloy Egress

**Resursă:** `monitoring/alloy-egress-policy`

**Problema rezolvată:** Policy-ul original permitea Alloy să trimită la `10.13.13.30:3100` (Loki vechi, inaccesibil). Cilium bloca silențios tot traficul spre `10.90.90.32:3100`.

**Fix aplicat:**
```yaml
- toCIDR:
  - 10.90.90.32/32       # era 10.13.13.30/32
  toPorts:
  - ports:
    - port: "3100"
      protocol: TCP
```

---

### 6. Grafana Dashboard

**URL:** `http://10.90.90.101:8087/d/fe273626-9df0-47d3-9398-130cd2e6a1b8/nginx-ip-monitor`

**Paneluri:**
| Panel | Tip | Query |
|-------|-----|-------|
| Log stream live | Logs | `{namespace=~"app1\|app2"} \| json \| ip != ""` |
| Top IP-uri | Bar chart | `topk(10, sum by (ip) (...))` |
| Top Țări | Pie chart | `sum by (country) (...)` |
| Requesturi în timp | Timeseries | `sum by (namespace) (count_over_time(...))` |

Auto-refresh: 10s.

---

## Queries utile în Grafana Explore (Loki)

```logql
# Toate requesturile cu IP real
{namespace=~"app1|app2"} | json | ip != ""

# Formatat simplu
{namespace=~"app1|app2"} | json | line_format "{{.ip}} [{{.country}}] {{.status}} {{.path}}"

# Top 10 IP-uri (ultimele 24h)
topk(10, sum by (ip) (count_over_time({namespace=~"app1|app2"} | json | ip != "" [24h])))

# Filtrare după IP specific
{namespace=~"app1|app2"} | json | ip = "1.2.3.4"

# Requesturi per țară
sum by (country) (count_over_time({namespace=~"app1|app2"} | json | country != "" [1h]))
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
