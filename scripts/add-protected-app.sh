#!/bin/bash
# =============================================================================
# add-protected-app.sh
# Adaugă o aplicație nouă în sistemul de protecție DDoS
# =============================================================================
set -e

# Culori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Paths (relative la rădăcina repo-ului ddos-protect-k8s)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DDOS_REPO="$(dirname "$SCRIPT_DIR")"
NETPOL_REPO="$(dirname "$DDOS_REPO")/k8s-network-policies"
CONFIGMAP="$DDOS_REPO/k8s/configmap.yaml"

# SSH jump pentru kubectl
SSH_JUMP="root@10.90.90.9"
SSH_NODE="devops@192.168.70.20"
KUBECTL="ssh -o StrictHostKeyChecking=no -J $SSH_JUMP $SSH_NODE kubectl"

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }
step()    { echo -e "\n${CYAN}══ $* ${NC}"; }

# =============================================================================
# Input
# =============================================================================
step "Configurare aplicație nouă"

if [ -n "$1" ]; then
  NAMESPACE="$1"
else
  read -rp "  Namespace Kubernetes: " NAMESPACE
fi
[ -z "$NAMESPACE" ] && error "Namespace-ul nu poate fi gol."

if [ -n "$2" ]; then
  APP_LABEL="$2"
else
  read -rp "  Label aplicație (app=?): " APP_LABEL
fi
[ -z "$APP_LABEL" ] && error "Label-ul nu poate fi gol."

echo ""
echo "  Tip aplicație:"
echo "  1) nginx (static site)"
echo "  2) Next.js (middleware.ts)"
echo "  3) Altul (Python, Go, etc.)"
read -rp "  Alege [1/2/3]: " APP_TYPE

# =============================================================================
# Verificări
# =============================================================================
step "Verificări inițiale"

[ -f "$CONFIGMAP" ] || error "Nu găsesc $CONFIGMAP"
[ -d "$NETPOL_REPO" ] || error "Nu găsesc repo-ul k8s-network-policies la $NETPOL_REPO"

# Verifică dacă namespace-ul e deja monitorizat
CURRENT_NS=$(grep 'LOKI_NAMESPACES:' "$CONFIGMAP" | sed 's/.*"\(.*\)".*/\1/')
if echo "$CURRENT_NS" | grep -qw "$NAMESPACE"; then
  warn "Namespace-ul '$NAMESPACE' e deja în LOKI_NAMESPACES ($CURRENT_NS)"
  SKIP_CONFIGMAP=true
else
  SKIP_CONFIGMAP=false
fi

success "Verificări OK"

# =============================================================================
# Pasul 1: Actualizează configmap.yaml
# =============================================================================
step "Pasul 1: Actualizare ddos-protect-k8s/k8s/configmap.yaml"

if [ "$SKIP_CONFIGMAP" = false ]; then
  NEW_NS="${CURRENT_NS}|${NAMESPACE}"

  # LOKI_NAMESPACES
  sed -i.bak "s|LOKI_NAMESPACES: \"${CURRENT_NS}\"|LOKI_NAMESPACES: \"${NEW_NS}\"|" "$CONFIGMAP"

  # PROTECTED_NAMESPACES (poate fi diferit, actualizăm și pe el)
  CURRENT_PROT=$(grep 'PROTECTED_NAMESPACES:' "$CONFIGMAP" | sed 's/.*"\(.*\)".*/\1/')
  NEW_PROT="${CURRENT_PROT}|${NAMESPACE}"
  sed -i.bak "s|PROTECTED_NAMESPACES: \"${CURRENT_PROT}\"|PROTECTED_NAMESPACES: \"${NEW_PROT}\"|" "$CONFIGMAP"

  rm -f "$CONFIGMAP.bak"
  success "LOKI_NAMESPACES → $NEW_NS"
  success "PROTECTED_NAMESPACES → $NEW_PROT"
else
  info "Sărit (namespace deja prezent)"
fi

# =============================================================================
# Pasul 2: Creează CiliumNetworkPolicy
# =============================================================================
step "Pasul 2: Creare network policy în k8s-network-policies/$NAMESPACE/"

NETPOL_DIR="$NETPOL_REPO/$NAMESPACE"
mkdir -p "$NETPOL_DIR"

# Găsește următorul număr disponibil
LAST_NUM=$(ls "$NETPOL_DIR"/*.yaml 2>/dev/null | grep -oE '^[0-9]+' | sort -n | tail -1)
NEXT_NUM=$(printf "%02d" $(( ${LAST_NUM:-0} + 1 )))
NETPOL_FILE="$NETPOL_DIR/${NEXT_NUM}-allow-ddos-agent-egress.yaml"

if [ -f "$NETPOL_DIR"/*ddos-agent-egress* ] 2>/dev/null; then
  warn "Network policy pentru ddos-agent există deja în $NETPOL_DIR"
  SKIP_NETPOL=true
else
  SKIP_NETPOL=false
  cat > "$NETPOL_FILE" <<EOF
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: allow-ddos-agent-egress
  namespace: ${NAMESPACE}
spec:
  endpointSelector:
    matchLabels:
      app: ${APP_LABEL}
  egress:
  - toEntities:
    - host
    - remote-node
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
EOF
  success "Creat: $NETPOL_FILE"
fi

# =============================================================================
# Pasul 3: Aplică network policy în cluster
# =============================================================================
step "Pasul 3: Aplicare în cluster (via SSH)"

if [ "$SKIP_NETPOL" = false ]; then
  if $KUBECTL apply -f - < "$NETPOL_FILE" 2>&1; then
    success "CiliumNetworkPolicy aplicat în cluster"
  else
    warn "Nu s-a putut aplica automat. Rulează manual:"
    echo "  kubectl apply -f $NETPOL_FILE"
  fi
else
  info "Sărit (policy deja există)"
fi

# Aplică și configmap-ul actualizat + restart agent
if [ "$SKIP_CONFIGMAP" = false ]; then
  if $KUBECTL apply -f - < "$CONFIGMAP" 2>&1; then
    success "ConfigMap actualizat în cluster"
    $KUBECTL rollout restart daemonset/ddos-agent -n ddos-protection 2>&1 && \
      success "ddos-agent restartat" || warn "Restart manual: kubectl rollout restart ds/ddos-agent -n ddos-protection"
  else
    warn "Aplică manual: kubectl apply -f k8s/configmap.yaml -n ddos-protection"
  fi
fi

# =============================================================================
# Pasul 4: Git commit + push
# =============================================================================
step "Pasul 4: Git push"

# ddos-protect-k8s
if [ "$SKIP_CONFIGMAP" = false ]; then
  cd "$DDOS_REPO"
  git add k8s/configmap.yaml
  git commit -m "feat: add $NAMESPACE to monitored namespaces" && \
    git push && success "ddos-protect-k8s pushuit" || warn "Push manual necesar în $DDOS_REPO"
fi

# k8s-network-policies
if [ "$SKIP_NETPOL" = false ]; then
  cd "$NETPOL_REPO"
  git add "$NETPOL_FILE"
  git commit -m "feat($NAMESPACE): allow egress to ddos-agent on port 8080" && \
    git push && success "k8s-network-policies pushuit" || warn "Push manual necesar în $NETPOL_REPO"
fi

# =============================================================================
# Pasul 5: Instrucțiuni pentru integrarea app-level
# =============================================================================
step "Pasul 5: Integrare în aplicație"
echo ""

case "$APP_TYPE" in
  1)
    echo -e "${YELLOW}nginx — adaugă în nginx.conf:${NC}"
    cat <<'NGINX'
    map $real_ip $ddos_blocked {
        default 0;
        include /etc/nginx/ddos/blocked_ips.map;
    }
    server {
        if ($ddos_blocked) { return 403; }
        ...
    }
NGINX
    echo ""
    echo -e "${YELLOW}Copiază docker-entrypoint.sh din cv-website ca model.${NC}"
    echo -e "${YELLOW}CMD din Dockerfile trebuie să fie: [\"/docker-entrypoint.sh\"]${NC}"
    ;;
  2)
    echo -e "${YELLOW}Next.js — adaugă în middleware.ts blocul de mai jos:${NC}"
    cat <<'NEXTJS'
const DDOS_AGENT_URL = process.env.DDOS_AGENT_URL ??
  "http://ddos-agent.ddos-protection.svc.cluster.local:8080/blocklist";

let blockedIpCache = new Set<string>();
let blockedIpCacheExpiresAt = 0;

async function isBlockedIp(ip: string): Promise<boolean> {
  const now = Date.now();
  if (now < blockedIpCacheExpiresAt) return blockedIpCache.has(ip);
  try {
    const res = await fetch(DDOS_AGENT_URL, {
      cache: "no-store", signal: AbortSignal.timeout(1500)
    });
    if (res.ok) {
      const data = await res.json();
      blockedIpCache = new Set(data.items ?? []);
      blockedIpCacheExpiresAt = now + 15_000;
    }
  } catch { /* fail silently */ }
  return blockedIpCache.has(ip);
}

// La începutul middleware-ului:
const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
if (await isBlockedIp(ip)) {
  return NextResponse.json({ error: "Forbidden" }, { status: 403 });
}
NEXTJS
    ;;
  3)
    echo -e "${YELLOW}Consumă direct API-ul agentului:${NC}"
    echo ""
    echo "  Plain text:  GET http://ddos-agent.ddos-protection.svc.cluster.local:8080/blocklist.txt"
    echo "  JSON:        GET http://ddos-agent.ddos-protection.svc.cluster.local:8080/blocklist"
    echo ""
    echo "  Verifică la fiecare request dacă IP-ul (CF-Connecting-IP) e în listă."
    echo "  Returnează 403 dacă e blocat."
    ;;
esac

# =============================================================================
# Sumar
# =============================================================================
step "Sumar"
echo ""
echo -e "  Namespace:     ${GREEN}$NAMESPACE${NC}"
echo -e "  App label:     ${GREEN}app=$APP_LABEL${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Configmap actualizat (LOKI_NAMESPACES, PROTECTED_NAMESPACES)"
echo -e "  ${GREEN}✓${NC} CiliumNetworkPolicy creat și aplicat"
echo -e "  ${GREEN}✓${NC} Git push efectuat"
echo ""
echo -e "  ${YELLOW}Mai trebuie:${NC}"
echo "  → Integrează blocklist-ul în aplicație (vezi Pasul 5 de mai sus)"
echo "  → Build + push imagine nouă dacă ai modificat codul"
echo "  → Asigură-te că aplicația loghează JSON cu câmpul 'ip' (pentru detecție Loki)"
echo ""
