# App Blocklist Integration (Cloudflare Tunnel Safe)

Pentru trafic prin Cloudflare Tunnel, blocarea la nivel L3/L4 (Cilium) nu este suficienta.
Aplica blocklist la nivel de aplicatie, pe `CF-Connecting-IP`.

## 1) Source of truth

`ddos-agent` sincronizeaza IP-urile blocate in ConfigMap:

- namespace: `ddos-protection`
- name: `ddos-blocklist`
- key: `blocked_ips.txt`

## 2) CV (nginx) integration

### Volum + mount in deployment

Adauga in deployment-ul `cv-website`:

```yaml
volumes:
  - name: ddos-blocklist
    configMap:
      name: ddos-blocklist
      optional: true
      items:
        - key: blocked_ips.txt
          path: blocked_ips.txt
```

```yaml
volumeMounts:
  - name: ddos-blocklist
    mountPath: /etc/nginx/ddos
    readOnly: true
```

### nginx.conf snippet

Include un fisier generat din `blocked_ips.txt` in etapa de start/reload.
Format asteptat pentru include:

```nginx
~^1\.2\.3\.4$ 1;
~^5\.6\.7\.8$ 1;
```

Snippet de folosire:

```nginx
map $http_cf_connecting_ip $ddos_blocked {
    default 0;
    include /etc/nginx/ddos/blocked_ips.map;
}

server {
    if ($ddos_blocked) { return 403; }
}
```

## 3) GAZ (Next.js middleware) integration

Pseudocod middleware:

```ts
const ip = req.headers.get("cf-connecting-ip")?.trim();
if (ip && blockedSet.has(ip)) {
  return new Response("Forbidden", { status: 403 });
}
```

`blockedSet` se incarca dintr-un fisier montat (`blocked_ips.txt`) sau din endpoint-ul agentului:

- `GET http://ddos-agent.ddos-protection.svc.cluster.local:8080/blocklist`

## 4) Agent endpoints

- `GET /blocklist` (JSON)
- `GET /blocklist.txt` (plain text, un IP pe linie)

## 5) Operational

1. `kubectl apply -f k8s/blocklist-configmap.yaml`
2. `kubectl apply -f k8s/rbac.yaml`
3. `kubectl apply -f k8s/configmap.yaml`
4. `kubectl -n ddos-protection rollout restart ds/ddos-agent`

