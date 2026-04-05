# Ghid Protecție DDoS — Kubernetes Cluster

## Cum funcționează sistemul

Sistemul detectează și blochează automat atacurile DDoS la **3 niveluri**:

```
Internet
    │
    ▼
Cloudflare Tunnel
    │  (1) Cloudflare blochează IP-ul la edge (dacă e în lista ddos_blocklist)
    │
    ▼
nginx / Next.js (aplicația ta)
    │  (2) Aplicația blochează IP-ul cu 403 înainte să proceseze requestul
    │
    ▼
Cilium (rețea Kubernetes)
    │  (3) Cilium poate dropa pachetele la nivel de rețea (dacă BLOCK_MODE=both)
```

### Componentele sistemului

**`ddos-agent`** (DaemonSet — rulează pe fiecare nod):
- Interoghează Loki la fiecare 5 secunde
- Numără requesturile per IP din log-urile aplicațiilor monitorizate
- Dacă un IP depășește `THRESHOLD_RPM` (implicit 20 req/min) → îl blochează
- Blochează în Cloudflare + Cilium (în funcție de `BLOCK_MODE`)
- Sincronizează lista de IP-uri blocate într-un ConfigMap
- Deblochează automat după `BLOCK_TTL_SECONDS` (implicit 600s = 10 min)
- Expune API pe portul 8080: `/blocked`, `/top`, `/events`, `/blocklist.txt`

**`ddos-controller`** (Deployment — 1 replică):
- Agregă rapoartele de la toți agenții
- Dacă un IP e blocat pe ≥ 3 noduri → aplică o politică Cilium globală pe cluster

**`docker-entrypoint.sh`** (în imaginea nginx — cv-website):
- La fiecare 15 secunde trage `/blocklist.txt` de la agent
- Convertește lista în format nginx map
- Face `nginx -s reload` ca să aplice noua listă

**`middleware.ts`** (în Next.js — calculatorgaz):
- La fiecare request verifică IP-ul clientului (`CF-Connecting-IP`)
- Dacă IP-ul e în cache-ul blocklist → returnează 403 imediat
- Cache-ul se reîmprospătează la fiecare 15 secunde de la agent

---

## Aplicații protejate acum

| Aplicație | Namespace | Tip blocare app-level |
|---|---|---|
| cv-website | `cv` | nginx map (`docker-entrypoint.sh`) |
| calculatorgaz | `gaz` | Next.js middleware |

---

## Cum adaugi o aplicație nouă

### Pasul 1 — Adaugă namespace-ul în `ddos-protect-k8s`

Editează `k8s/configmap.yaml` și adaugă namespace-ul în regex:

```yaml
LOKI_NAMESPACES: "cv|gaz|NAMESPACE_NOU"
PROTECTED_NAMESPACES: "cv|gaz|NAMESPACE_NOU"
```

Aplică și fă push:
```bash
kubectl apply -f k8s/configmap.yaml -n ddos-protection
kubectl -n ddos-protection rollout restart daemonset/ddos-agent
git add k8s/configmap.yaml && git commit -m "feat: add NAMESPACE_NOU to monitored namespaces" && git push
```

---

### Pasul 2 — Asigură-te că aplicația loghează JSON cu câmpul `ip`

Agentul citește log-urile din Loki și caută câmpul `ip`. Log-ul trebuie să fie în format JSON.

**Pentru nginx** — în `nginx.conf`:
```nginx
map $http_cf_connecting_ip $real_ip {
    ""      $remote_addr;
    default $http_cf_connecting_ip;
}

log_format json_cf escape=json
    '{"time":"$time_iso8601","ip":"$real_ip","status":$status,"path":"$request_uri"}';

access_log /dev/stdout json_cf;
```

**Pentru Next.js** — în `middleware.ts` (deja ai exemplu în calculatorgaz):
```typescript
console.log(JSON.stringify({
    time: new Date().toISOString(),
    ip: request.headers.get("cf-connecting-ip") ?? "unknown",
    path: request.nextUrl.pathname,
}));
```

---

### Pasul 3 — Integrează blocklist-ul în aplicație

#### Varianta A: nginx (static site)

Copiază `docker-entrypoint.sh` și `nginx.conf` din `cv-website` ca model.

Adaugă în `nginx.conf`:
```nginx
map $real_ip $ddos_blocked {
    default 0;
    include /etc/nginx/ddos/blocked_ips.map;
}

server {
    if ($ddos_blocked) { return 403; }
    ...
}
```

`docker-entrypoint.sh` se ocupă automat de descărcarea și reîncărcarea listei.

#### Varianta B: Next.js

Copiază blocul DDoS din `middleware.ts` al calculatorgaz:

```typescript
const DDOS_AGENT_URL = process.env.DDOS_AGENT_URL ?? 
  "http://ddos-agent.ddos-protection.svc.cluster.local:8080/blocklist";

let blockedIpCache = new Set<string>();
let blockedIpCacheExpiresAt = 0;

async function isBlockedIp(ip: string): Promise<boolean> {
  const now = Date.now();
  if (now < blockedIpCacheExpiresAt) return blockedIpCache.has(ip);
  
  try {
    const res = await fetch(DDOS_AGENT_URL, { 
      cache: "no-store",
      signal: AbortSignal.timeout(1500) 
    });
    if (res.ok) {
      const data = await res.json();
      blockedIpCache = new Set(data.items ?? []);
      blockedIpCacheExpiresAt = now + 15_000;
    }
  } catch { /* fail silently */ }
  
  return blockedIpCache.has(ip);
}

// În middleware:
export async function middleware(request: NextRequest) {
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  if (await isBlockedIp(ip)) {
    return NextResponse.json({ error: "Forbidden" }, { status: 403 });
  }
  // ... restul middleware-ului
}
```

#### Varianta C: altă aplicație (Python, Go, etc.)

Poți consuma direct API-ul agentului:
```bash
# Plain text (un IP per linie)
GET http://ddos-agent.ddos-protection.svc.cluster.local:8080/blocklist.txt

# JSON
GET http://ddos-agent.ddos-protection.svc.cluster.local:8080/blocklist
```

---

### Pasul 4 — Network policy (obligatoriu)

Aplicația ta are nevoie de permisiune să comunice cu ddos-agent pe portul 8080.

Creează `k8s-network-policies/NAMESPACE_NOU/XX-allow-ddos-agent-egress.yaml`:

```yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: allow-ddos-agent-egress
  namespace: NAMESPACE_NOU
spec:
  endpointSelector:
    matchLabels:
      app: LABEL_APP_TU
  egress:
  - toEntities:
    - host
    - remote-node
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
```

> **De ce `host` și `remote-node` și nu podSelector?**
> ddos-agent rulează cu `hostNetwork: true` — folosește IP-ul nodului, nu un IP de pod.
> Cilium clasifică traficul spre node IPs ca `host` (nodul local) sau `remote-node` (alt nod).
> Un simplu `podSelector` sau `ipBlock` nu funcționează în acest caz.

Aplică imediat:
```bash
kubectl apply -f k8s-network-policies/NAMESPACE_NOU/XX-allow-ddos-agent-egress.yaml
```

Și fă push ca să fie persistent:
```bash
cd k8s-network-policies
git add . && git commit -m "feat(NAMESPACE_NOU): allow egress to ddos-agent" && git push
```

---

### Pasul 5 — Verificare

```bash
# Testează că aplicatia poate ajunge la agent
kubectl exec -n NAMESPACE_NOU <pod-name> -- \
  curl -s http://ddos-agent.ddos-protection.svc.cluster.local:8080/health

# Răspuns așteptat:
# {"node":"w1","status":"ok"}
```

---

## Comenzi utile

```bash
# Vezi IP-urile blocate acum (pe toate nodurile)
for pod in $(kubectl get pods -n ddos-protection -l app=ddos-agent -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $pod ==="
  kubectl exec -n ddos-protection $pod -- wget -qO- 'http://127.0.0.1:8080/blocked' 2>/dev/null
done

# Top IP-uri după trafic (ultimul scan Loki)
kubectl exec -n ddos-protection <ddos-agent-pod> -- \
  wget -qO- 'http://127.0.0.1:8080/top?limit=20' 2>/dev/null | jq

# Blochează manual un IP
kubectl exec -n ddos-protection <ddos-agent-pod> -- \
  wget -qO- --post-data='{"ip":"1.2.3.4"}' \
  --header='Content-Type: application/json' \
  'http://127.0.0.1:8080/block' 2>/dev/null

# Deblochează manual un IP
kubectl exec -n ddos-protection <ddos-agent-pod> -- \
  wget -qO- --post-data='{"ip":"1.2.3.4"}' \
  --header='Content-Type: application/json' \
  'http://127.0.0.1:8080/unblock' 2>/dev/null

# Verifică blocklist-ul din nginx (cv-website)
kubectl exec -n cv <cv-pod> -- cat /etc/nginx/ddos/blocked_ips.map

# Logs agent (detecții + blocări)
kubectl -n ddos-protection logs -l app=ddos-agent --tail=50 | grep -i "attack\|block\|error"
```

---

## Configurație (ddos-protect-k8s/k8s/configmap.yaml)

| Variabilă | Valoare implicită | Descriere |
|---|---|---|
| `THRESHOLD_RPM` | `20` | Pragul de detecție (req/min per IP) |
| `BLOCK_TTL_SECONDS` | `600` | Cât timp rămâne blocat IP-ul (10 min) |
| `POLL_INTERVAL_SECONDS` | `5` | Frecvența interogării Loki |
| `BLOCK_MODE` | `cloudflare` | `cloudflare`, `cilium`, sau `both` |
| `LOKI_NAMESPACES` | `cv\|gaz` | Namespace-uri monitorizate (regex) |
| `TRUSTED_CIDRS` | rețele interne | IP-uri care nu se blochează niciodată |

> **Atenție:** `THRESHOLD_RPM: 20` e foarte mic pentru producție.
> Un utilizator normal care navighează rapid poate depăși 20 req/min.
> Consideră să îl crești la `100`-`200` pentru aplicații publice.
