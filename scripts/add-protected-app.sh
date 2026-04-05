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

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DDOS_REPO="$(dirname "$SCRIPT_DIR")"
NETPOL_REPO="$(dirname "$DDOS_REPO")/k8s-network-policies"
CONFIGMAP="$DDOS_REPO/k8s/configmap.yaml"
CV_WEBSITE="$(dirname "$DDOS_REPO")/cv-website"

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

if [ -n "$1" ]; then NAMESPACE="$1"; else read -rp "  Namespace Kubernetes: " NAMESPACE; fi
[ -z "$NAMESPACE" ] && error "Namespace-ul nu poate fi gol."

# --- Detectare automată label din cluster ---
info "Detectez pods în namespace '$NAMESPACE' ..."
POD_INFO=$($KUBECTL get pods -n "$NAMESPACE" --no-headers 2>/dev/null | head -5)
if [ -z "$POD_INFO" ]; then
  warn "Nu găsesc pods în namespace '$NAMESPACE'. Introduci manual."
  read -rp "  Label aplicație (app=?): " APP_LABEL
else
  echo ""
  echo "  Pods găsite:"
  $KUBECTL get pods -n "$NAMESPACE" --show-labels --no-headers 2>/dev/null | \
    awk '{printf "    %-45s %s\n", $1, $NF}' | head -10

  # Extrage toate valorile unice de app= din labels
  DETECTED_LABELS=$($KUBECTL get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.labels.app}{"\n"}{end}' 2>/dev/null | sort -u | grep -v '^$')

  if [ -n "$DETECTED_LABELS" ]; then
    echo ""
    echo "  Labels detectate (app=):"
    i=1
    while IFS= read -r lbl; do
      echo "    $i) $lbl"
      i=$((i+1))
    done <<< "$DETECTED_LABELS"

    echo "    $i) Introduc manual"
    read -rp "  Alege [1-$i]: " LABEL_CHOICE

    LABEL_COUNT=$(echo "$DETECTED_LABELS" | wc -l | tr -d ' ')
    if [ "$LABEL_CHOICE" -le "$LABEL_COUNT" ] 2>/dev/null; then
      APP_LABEL=$(echo "$DETECTED_LABELS" | sed -n "${LABEL_CHOICE}p")
      success "Label selectat: app=$APP_LABEL"
    else
      read -rp "  Label aplicație (app=?): " APP_LABEL
    fi
  else
    warn "Nu am găsit label 'app=' pe pods. Introduci manual."
    read -rp "  Label aplicație (app=?): " APP_LABEL
  fi
fi
[ -z "$APP_LABEL" ] && error "Label-ul nu poate fi gol."

# --- Detectare automată tip aplicație din imaginea containerului ---
info "Detectez tipul aplicației din imagine ..."
CONTAINER_IMAGE=$($KUBECTL get pods -n "$NAMESPACE" -l "app=$APP_LABEL" \
  -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null)

if echo "$CONTAINER_IMAGE" | grep -qi "nginx"; then
  DETECTED_TYPE="1"
  info "Detectat: nginx ($CONTAINER_IMAGE)"
elif echo "$CONTAINER_IMAGE" | grep -qi "node\|next"; then
  DETECTED_TYPE="2"
  info "Detectat: Next.js ($CONTAINER_IMAGE)"
else
  DETECTED_TYPE=""
  info "Imagine: $CONTAINER_IMAGE"
fi

echo ""
echo "  Tip aplicație:"
echo "  1) nginx (static site)"
echo "  2) Next.js (middleware.ts)"
echo "  3) Altul (manual)"
if [ -n "$DETECTED_TYPE" ]; then
  read -rp "  Alege [1/2/3] (detectat: $DETECTED_TYPE): " APP_TYPE
  APP_TYPE="${APP_TYPE:-$DETECTED_TYPE}"
else
  read -rp "  Alege [1/2/3]: " APP_TYPE
fi

echo ""
read -rp "  URL repo Git (SSH sau HTTPS, Enter pentru skip): " APP_REPO_URL

# =============================================================================
# Verificări
# =============================================================================
step "Verificări inițiale"

[ -f "$CONFIGMAP" ] || error "Nu găsesc $CONFIGMAP"
[ -d "$NETPOL_REPO" ] || error "Nu găsesc repo-ul k8s-network-policies la $NETPOL_REPO"

CURRENT_NS=$(grep 'LOKI_NAMESPACES:' "$CONFIGMAP" | sed 's/.*"\(.*\)".*/\1/')
if echo "$CURRENT_NS" | grep -qw "$NAMESPACE"; then
  warn "Namespace-ul '$NAMESPACE' e deja în LOKI_NAMESPACES"
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
  CURRENT_PROT=$(grep 'PROTECTED_NAMESPACES:' "$CONFIGMAP" | sed 's/.*"\(.*\)".*/\1/')
  NEW_PROT="${CURRENT_PROT}|${NAMESPACE}"

  python3 - <<PYEOF
content = open("$CONFIGMAP").read()
content = content.replace('LOKI_NAMESPACES: "$CURRENT_NS"', 'LOKI_NAMESPACES: "$NEW_NS"')
content = content.replace('PROTECTED_NAMESPACES: "$CURRENT_PROT"', 'PROTECTED_NAMESPACES: "$NEW_PROT"')
open("$CONFIGMAP", "w").write(content)
PYEOF
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

if ls "$NETPOL_DIR"/*ddos-agent-egress* &>/dev/null; then
  warn "Network policy pentru ddos-agent există deja"
  SKIP_NETPOL=true
else
  SKIP_NETPOL=false
  LAST_NUM=$(ls "$NETPOL_DIR"/*.yaml 2>/dev/null | xargs -I{} basename {} | grep -oE '^[0-9]+' | sort -n | tail -1)
  NEXT_NUM=$(printf "%02d" $(( ${LAST_NUM:-0} + 1 )))
  NETPOL_FILE="$NETPOL_DIR/${NEXT_NUM}-allow-ddos-agent-egress.yaml"

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
# Pasul 3: Aplică în cluster
# =============================================================================
step "Pasul 3: Aplicare în cluster (via SSH)"

if [ "$SKIP_NETPOL" = false ]; then
  $KUBECTL apply -f - < "$NETPOL_FILE" && success "CiliumNetworkPolicy aplicat" || \
    warn "Aplică manual: kubectl apply -f $NETPOL_FILE"
fi

if [ "$SKIP_CONFIGMAP" = false ]; then
  $KUBECTL apply -f - < "$CONFIGMAP" && success "ConfigMap actualizat în cluster" || \
    warn "Aplică manual: kubectl apply -f k8s/configmap.yaml -n ddos-protection"
  $KUBECTL rollout restart daemonset/ddos-agent -n ddos-protection && \
    success "ddos-agent restartat" || warn "Restart manual necesar"
fi

# =============================================================================
# Pasul 4: Git push (ddos-protect-k8s + k8s-network-policies)
# =============================================================================
step "Pasul 4: Git push infra"

if [ "$SKIP_CONFIGMAP" = false ]; then
  cd "$DDOS_REPO"
  git add k8s/configmap.yaml
  git commit -m "feat: add $NAMESPACE to monitored namespaces" && \
    git push && success "ddos-protect-k8s pushuit" || warn "Push manual necesar în $DDOS_REPO"
fi

if [ "$SKIP_NETPOL" = false ]; then
  cd "$NETPOL_REPO"
  git add "$NETPOL_FILE"
  git commit -m "feat($NAMESPACE): allow egress to ddos-agent on port 8080" && \
    git push && success "k8s-network-policies pushuit" || warn "Push manual necesar în $NETPOL_REPO"
fi

# =============================================================================
# Pasul 5: Integrare în repo-ul aplicației
# =============================================================================
step "Pasul 5: Integrare în aplicație"

if [ -z "$APP_REPO_URL" ]; then
  warn "URL repo lipsă — sări integrarea automată"
else
  CLONE_DIR=$(mktemp -d)
  info "Clonez $APP_REPO_URL în $CLONE_DIR ..."
  git clone "$APP_REPO_URL" "$CLONE_DIR" || error "Clone eșuat pentru $APP_REPO_URL"
  success "Repo clonat"

  case "$APP_TYPE" in
    # --------------------------------------------------------------------------
    # nginx
    # --------------------------------------------------------------------------
    1)
      # Găsește nginx.conf și Dockerfile
      NGINX_CONF=$(find "$CLONE_DIR" -name "nginx.conf" | head -1)
      DOCKERFILE=$(find "$CLONE_DIR" -name "Dockerfile" | head -1)
      [ -z "$NGINX_CONF" ] && error "Nu găsesc nginx.conf în repo."
      [ -z "$DOCKERFILE" ] && error "Nu găsesc Dockerfile în repo."

      REPO_ROOT=$(dirname "$DOCKERFILE")
      ENTRYPOINT="$REPO_ROOT/docker-entrypoint.sh"

      # Copiază docker-entrypoint.sh din cv-website dacă nu există
      if [ -f "$ENTRYPOINT" ]; then
        info "docker-entrypoint.sh există deja — sărit"
      else
        if [ -f "$CV_WEBSITE/docker-entrypoint.sh" ]; then
          cp "$CV_WEBSITE/docker-entrypoint.sh" "$ENTRYPOINT"
          success "Copiat docker-entrypoint.sh din cv-website"
        else
          # Creează din template dacă cv-website nu e disponibil
          cat > "$ENTRYPOINT" <<'ENTRYEOF'
#!/bin/sh
set -eu

BLOCKLIST_URL="${BLOCKLIST_URL:-http://ddos-agent.ddos-protection.svc.cluster.local:8080/blocklist.txt}"
SYNC_INTERVAL="${BLOCKLIST_SYNC_INTERVAL_SECONDS:-15}"
BLOCKLIST_MAP_PATH="/etc/nginx/ddos/blocked_ips.map"

mkdir -p /etc/nginx/ddos
[ -f "$BLOCKLIST_MAP_PATH" ] || printf "# empty\n" > "$BLOCKLIST_MAP_PATH"

update_blocklist_map() {
  tmp_txt="/tmp/blocked_ips.txt"
  tmp_map="/tmp/blocked_ips.map"
  if ! curl -fsS --max-time 3 "$BLOCKLIST_URL" -o "$tmp_txt"; then
    return 1
  fi
  {
    echo "# generated by docker-entrypoint.sh"
    sed 's/\r$//' "$tmp_txt" \
      | awk 'NF {print $1}' \
      | grep -E '^[0-9]+(\.[0-9]+){3}$' \
      | sort -u \
      | sed 's/\./\\./g' \
      | awk '{printf("~^%s$ 1;\n", $0)}'
  } > "$tmp_map"
  mv "$tmp_map" "$BLOCKLIST_MAP_PATH"
  return 0
}

update_blocklist_map || true

(
  while true; do
    sleep "$SYNC_INTERVAL"
    if update_blocklist_map; then
      nginx -s reload >/dev/null 2>&1 || true
    fi
  done
) &

exec nginx -g 'daemon off;'
ENTRYEOF
          success "Creat docker-entrypoint.sh din template"
        fi
      fi

      # Actualizează nginx.conf cu blocklist map + filter
      python3 - <<PYEOF
content = open("$NGINX_CONF").read()

# Adaugă map block dacă nu există deja
if "ddos_blocked" not in content:
    map_block = '''
    map \$real_ip \$ddos_blocked {
        default 0;
        include /etc/nginx/ddos/blocked_ips.map;
    }
'''
    # Inserează după primul map block existent sau înainte de server {
    if 'map \$http_cf_connecting_ip' in content:
        idx = content.find('\n    server {')
        content = content[:idx] + map_block + content[idx:]
    else:
        idx = content.find('\n    server {')
        content = content[:idx] + map_block + content[idx:]

# Adaugă if block în server dacă nu există deja
if '\$ddos_blocked' not in content or 'return 403' not in content:
    server_open = content.find('server {')
    # Găsește după listen/server_name, înainte de root/location
    idx = content.find('\n        root ', server_open)
    if idx == -1:
        idx = content.find('\n        location ', server_open)
    if idx != -1:
        inject = '''
        if (\$ddos_blocked) {
            return 403;
        }
'''
        content = content[:idx] + inject + content[idx:]

open("$NGINX_CONF", "w").write(content)
print("nginx.conf actualizat")
PYEOF
      success "nginx.conf actualizat cu DDoS filter"

      # Actualizează Dockerfile
      python3 - <<PYEOF
content = open("$DOCKERFILE").read()
changed = False

# Adaugă COPY + chmod pentru entrypoint dacă nu există
if "docker-entrypoint.sh" not in content:
    # Inserează înainte de CMD
    cmd_idx = content.rfind('\nCMD ')
    inject = '\nCOPY docker-entrypoint.sh /docker-entrypoint.sh\nRUN chmod +x /docker-entrypoint.sh\n'
    content = content[:cmd_idx] + inject + content[cmd_idx:]
    changed = True

# Schimbă CMD
import re
new_content = re.sub(
    r'CMD\s+\[.*nginx.*\]',
    'CMD ["/docker-entrypoint.sh"]',
    content
)
if new_content != content:
    content = new_content
    changed = True

open("$DOCKERFILE", "w").write(content)
print("Dockerfile actualizat" if changed else "Dockerfile deja actualizat")
PYEOF
      success "Dockerfile actualizat (CMD → /docker-entrypoint.sh)"
      ;;

    # --------------------------------------------------------------------------
    # Next.js
    # --------------------------------------------------------------------------
    2)
      MIDDLEWARE=$(find "$CLONE_DIR" -name "middleware.ts" | head -1)
      [ -z "$MIDDLEWARE" ] && error "Nu găsesc middleware.ts în repo."

      python3 - <<PYEOF
content = open("$MIDDLEWARE").read()

if "isDdosBlocked" in content or "isBlockedIp" in content or "ddos-agent" in content:
    print("DDoS block deja prezent în middleware.ts — sărit")
else:
    ddos_block = '''// ---------------------------------------------------------------------------
// DDoS blocklist (fetched from ddos-agent, cached in memory)
// ---------------------------------------------------------------------------
const DDOS_AGENT_URL =
  process.env.DDOS_AGENT_URL ??
  "http://ddos-agent.ddos-protection.svc.cluster.local:8080/blocklist";

let _blockedIpCache = new Set<string>();
let _blockedIpCacheExpiresAt = 0;

async function isBlockedIp(ip: string): Promise<boolean> {
  if (!ip || ip === "unknown") return false;
  const now = Date.now();
  if (now < _blockedIpCacheExpiresAt) return _blockedIpCache.has(ip);
  try {
    const res = await fetch(DDOS_AGENT_URL, {
      cache: "no-store",
      signal: AbortSignal.timeout(1500),
    });
    if (res.ok) {
      const data = await res.json();
      _blockedIpCache = new Set(data.items ?? []);
      _blockedIpCacheExpiresAt = now + 15_000;
    }
  } catch { /* fail silently */ }
  return _blockedIpCache.has(ip);
}

'''
    # Inserează după imports (după ultima linie care începe cu import)
    lines = content.split("\n")
    last_import = 0
    for i, line in enumerate(lines):
        if line.startswith("import "):
            last_import = i
    lines.insert(last_import + 1, ddos_block)
    content = "\n".join(lines)

    # Înlocuiește export function middleware cu export async function
    content = content.replace(
        "export function middleware(",
        "export async function middleware("
    )

    # Injectează check la începutul middleware-ului
    mw_start = content.find("export async function middleware(")
    body_start = content.find("{", mw_start) + 1
    # Găsește primul newline după {
    nl = content.find("\n", body_start)
    check = """
  const _ip = request.headers.get("cf-connecting-ip")?.trim() ||
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || "unknown";
  if (await isBlockedIp(_ip)) {
    if (request.nextUrl.pathname.startsWith("/api/")) {
      return NextResponse.json({ error: "Forbidden" }, { status: 403 });
    }
    return new NextResponse("Forbidden", { status: 403 });
  }
"""
    content = content[:nl] + check + content[nl:]
    open("$MIDDLEWARE", "w").write(content)
    print("middleware.ts actualizat cu DDoS block")
PYEOF
      success "middleware.ts actualizat"
      ;;

    3)
      warn "Tip 'Altul' — integrarea manuală e necesară."
      echo "  Consumă: http://ddos-agent.ddos-protection.svc.cluster.local:8080/blocklist.txt"
      ;;
  esac

  # Commit + push în repo-ul aplicației
  cd "$CLONE_DIR"
  git config user.email "ddos-script@local" 2>/dev/null || true
  git config user.name "ddos-script" 2>/dev/null || true

  if git diff --quiet && git diff --staged --quiet; then
    info "Nu sunt modificări în repo-ul aplicației"
  else
    git add -A
    git commit -m "feat: integrate DDoS blocklist protection via ddos-agent"
    git push && success "Repo aplicație pushuit: $APP_REPO_URL" || \
      warn "Push eșuat — verifică permisiunile SSH/token pentru $APP_REPO_URL"
  fi

  rm -rf "$CLONE_DIR"
fi

# =============================================================================
# Sumar
# =============================================================================
step "Sumar final"
echo ""
echo -e "  Namespace:  ${GREEN}$NAMESPACE${NC}"
echo -e "  App label:  ${GREEN}app=$APP_LABEL${NC}"
echo -e "  Repo:       ${GREEN}${APP_REPO_URL:-manual}${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} LOKI_NAMESPACES + PROTECTED_NAMESPACES actualizate"
echo -e "  ${GREEN}✓${NC} CiliumNetworkPolicy creat și aplicat"
echo -e "  ${GREEN}✓${NC} ddos-agent restartat"
echo -e "  ${GREEN}✓${NC} Git push efectuat (infra)"
[ -n "$APP_REPO_URL" ] && echo -e "  ${GREEN}✓${NC} Aplicație modificată și pushuit"
echo ""
if [ -n "$APP_REPO_URL" ]; then
  echo -e "  ${YELLOW}Mai trebuie:${NC}"
  echo "  → Build + push imagine nouă (CI/CD sau manual)"
  echo "  → Asigură-te că aplicația loghează JSON cu câmpul 'ip'"
fi
echo ""
