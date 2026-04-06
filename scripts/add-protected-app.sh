#!/bin/bash
# =============================================================================
# add-protected-app.sh <app-repo-url> [gitops-repo-url]
# Flux: clone repo app → detectează tip → modifică → push
#       + infra (configmap în repo corect + network policy)
# =============================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DDOS_REPO="$(dirname "$SCRIPT_DIR")"
NETPOL_REPO="$(dirname "$DDOS_REPO")/k8s-network-policies"
CONFIGMAP="$DDOS_REPO/k8s/configmap.yaml"
CONFIGMAP_GIT_ROOT="$DDOS_REPO"
CONFIGMAP_GIT_ADD_PATH="k8s/configmap.yaml"
CONFIGMAP_REPO_LABEL="ddos-protect-k8s (local)"
CV_WEBSITE="$(dirname "$DDOS_REPO")/cv-website"
GITOPS_REPO_URL="${2:-}"
GITOPS_CLONE_DIR=""

SSH_JUMP="root@10.90.90.9"
SSH_NODE="devops@192.168.70.20"
KUBECTL="ssh -n -o StrictHostKeyChecking=no -J $SSH_JUMP $SSH_NODE kubectl"

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }
step()    { echo -e "\n${CYAN}══ $* ${NC}"; }
normalize_repo_url() {
  echo "$1" | sed -E 's/\.git$//' | sed -E 's:/*$::'
}

# =============================================================================
# Pasul 1: Repo URL + clone
# =============================================================================
step "Clone repo aplicație"

if [ -n "$1" ]; then
  APP_REPO_URL="$1"
else
  read -rp "  URL repo Git (SSH sau HTTPS): " APP_REPO_URL
  [ -z "$APP_REPO_URL" ] && error "URL-ul nu poate fi gol."
fi
APP_REPO_URL_NORM="$(normalize_repo_url "$APP_REPO_URL")"

if [ -z "$GITOPS_REPO_URL" ]; then
  read -rp "  URL repo GitOps/ArgoCD (opțional, Enter = skip): " GITOPS_REPO_URL || true
fi

if [ -n "$GITOPS_REPO_URL" ]; then
  GITOPS_REPO_URL_NORM="$(normalize_repo_url "$GITOPS_REPO_URL")"
  GITOPS_CLONE_DIR=$(mktemp -d)
  info "Clonez repo GitOps $GITOPS_REPO_URL ..."
  git clone "$GITOPS_REPO_URL" "$GITOPS_CLONE_DIR" || error "Clone eșuat pentru $GITOPS_REPO_URL"
  success "Repo GitOps clonat"

  GITOPS_CONFIGMAP="$GITOPS_CLONE_DIR/k8s/configmap.yaml"
  if [ -f "$GITOPS_CONFIGMAP" ]; then
    CONFIGMAP="$GITOPS_CONFIGMAP"
  else
    GITOPS_CONFIGMAP=$(rg -l 'LOKI_NAMESPACES:|PROTECTED_NAMESPACES:' "$GITOPS_CLONE_DIR" -g '*.yaml' -g '*.yml' | head -1 || true)
    [ -n "$GITOPS_CONFIGMAP" ] && CONFIGMAP="$GITOPS_CONFIGMAP"
  fi

  if [ "$CONFIGMAP" = "$DDOS_REPO/k8s/configmap.yaml" ]; then
    warn "Nu am găsit configmap în repo GitOps, rămân pe $CONFIGMAP"
  else
    CONFIGMAP_GIT_ROOT="$GITOPS_CLONE_DIR"
    CONFIGMAP_GIT_ADD_PATH="${CONFIGMAP#$GITOPS_CLONE_DIR/}"
    CONFIGMAP_REPO_LABEL="$GITOPS_REPO_URL"
    success "ConfigMap detectat în GitOps: $CONFIGMAP_GIT_ADD_PATH"
  fi
else
  GITOPS_REPO_URL_NORM=""
fi

CLONE_DIR=$(mktemp -d)
info "Clonez $APP_REPO_URL ..."
git clone "$APP_REPO_URL" "$CLONE_DIR" || error "Clone eșuat pentru $APP_REPO_URL"
success "Repo clonat"

# =============================================================================
# Pasul 2: Detectare tip aplicație din fișierele repo-ului
# =============================================================================
step "Detectare tip aplicație"

APP_TYPE=""

# nginx — are nginx.conf
if find "$CLONE_DIR" -name "nginx.conf" | grep -q .; then
  APP_TYPE="nginx"
  info "Detectat: nginx (găsit nginx.conf)"
fi

# nextjs — are middleware.ts SAU package.json cu "next"
if [ -z "$APP_TYPE" ]; then
  if find "$CLONE_DIR" -name "middleware.ts" | grep -q .; then
    APP_TYPE="nextjs"
    info "Detectat: Next.js (găsit middleware.ts)"
  elif find "$CLONE_DIR" -name "package.json" | head -1 | xargs grep -l '"next"' 2>/dev/null | grep -q .; then
    APP_TYPE="nextjs"
    info "Detectat: Next.js (next în package.json)"
  fi
fi

# node/express — are package.json
if [ -z "$APP_TYPE" ] && find "$CLONE_DIR" -maxdepth 3 -name "package.json" | grep -q .; then
  APP_TYPE="node"
  info "Detectat: Node.js (găsit package.json)"
fi

# python — are requirements.txt sau setup.py sau pyproject.toml
if [ -z "$APP_TYPE" ] && find "$CLONE_DIR" -maxdepth 3 \( -name "requirements.txt" -o -name "setup.py" -o -name "pyproject.toml" \) | grep -q .; then
  APP_TYPE="python"
  info "Detectat: Python"
fi

# go — are go.mod
if [ -z "$APP_TYPE" ] && find "$CLONE_DIR" -maxdepth 3 -name "go.mod" | grep -q .; then
  APP_TYPE="go"
  info "Detectat: Go"
fi

# java — are pom.xml sau build.gradle
if [ -z "$APP_TYPE" ] && find "$CLONE_DIR" -maxdepth 3 \( -name "pom.xml" -o -name "build.gradle" -o -name "build.gradle.kts" \) | grep -q .; then
  APP_TYPE="java"
  info "Detectat: Java"
fi

# dotnet — are .csproj sau .sln
if [ -z "$APP_TYPE" ] && find "$CLONE_DIR" -maxdepth 3 \( -name "*.csproj" -o -name "*.sln" \) | grep -q .; then
  APP_TYPE="dotnet"
  info "Detectat: .NET"
fi

if [ -z "$APP_TYPE" ]; then
  APP_TYPE="unknown"
  warn "Nu am putut detecta tipul aplicației din fișierele repo-ului."
fi

success "Tip: $APP_TYPE"

# =============================================================================
# Pasul 3: Modificare repo aplicație
# =============================================================================
step "Modificare fișiere"

case "$APP_TYPE" in
  # --------------------------------------------------------------------------
  nginx)
  # --------------------------------------------------------------------------
    NGINX_CONF=$(find "$CLONE_DIR" -name "nginx.conf" | head -1)
    DOCKERFILE=$(find "$CLONE_DIR" -name "Dockerfile" | head -1)
    [ -z "$NGINX_CONF" ] && error "Nu găsesc nginx.conf în repo."
    [ -z "$DOCKERFILE" ] && error "Nu găsesc Dockerfile în repo."

    REPO_ROOT=$(dirname "$DOCKERFILE")
    ENTRYPOINT="$REPO_ROOT/docker-entrypoint.sh"

    if [ -f "$ENTRYPOINT" ]; then
      info "docker-entrypoint.sh există deja — sărit"
    elif [ -f "$CV_WEBSITE/docker-entrypoint.sh" ]; then
      cp "$CV_WEBSITE/docker-entrypoint.sh" "$ENTRYPOINT"
      success "Copiat docker-entrypoint.sh din cv-website"
    else
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
  if ! curl -fsS --max-time 3 "$BLOCKLIST_URL" -o "$tmp_txt"; then return 1; fi
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
}

update_blocklist_map || true

(
  while true; do
    sleep "$SYNC_INTERVAL"
    update_blocklist_map && nginx -s reload >/dev/null 2>&1 || true
  done
) &

exec nginx -g 'daemon off;'
ENTRYEOF
      success "Creat docker-entrypoint.sh din template"
    fi

    APP_NGINX_CONF="$NGINX_CONF" APP_REPO_DIR="$CLONE_DIR" python3 - <<'PYEOF'
import os
import re
from pathlib import Path

content = open(os.environ["APP_NGINX_CONF"]).read()
changed = False

real_ip_map = """map $http_cf_connecting_ip $real_ip {
  ""      $remote_addr;
  default $http_cf_connecting_ip;
}

"""
ddos_map = """map $real_ip $ddos_blocked {
  default 0;
  include /etc/nginx/ddos/blocked_ips.map;
}

"""
country_map = """map $http_cf_ipcountry $ddos_country {
  ""      "-";
  default $http_cf_ipcountry;
}

"""
ddos_log_format = """log_format ddos_json escape=json '{"ip":"$real_ip","country":"$ddos_country","method":"$request_method","path":"$uri","status":"$status"}';
access_log /dev/stdout ddos_json;

"""

real_ip_map_re = re.compile(r'(?m)^\s*map\s+\$http_cf_connecting_ip\s+\$real_ip\s*\{')
ddos_map_re = re.compile(r'(?m)^\s*map\s+\$real_ip\s+\$ddos_blocked\s*\{')
country_map_re = re.compile(r'(?m)^\s*map\s+\$http_cf_ipcountry\s+\$ddos_country\s*\{')
http_open_re = re.compile(r'(?m)^\s*http\s*\{')
ddos_log_re = re.compile(r'(?m)^\s*log_format\s+ddos_json\s+')

def insert_after_http_open(text, block):
    m = http_open_re.search(text)
    if not m:
        # Fallback pentru fișiere incluse deja în context http
        return block + text
    nl = text.find('\n', m.end())
    if nl == -1:
        return text + "\n" + block
    return text[:nl + 1] + block + text[nl + 1:]

def find_real_ip_map_end(text):
    m = re.search(r'(?ms)^\s*map\s+\$http_cf_connecting_ip\s+\$real_ip\s*\{.*?^\s*\}\s*', text)
    return m.end() if m else -1

# Adaugă map $real_ip doar dacă lipsește map-ul custom (nu după simplul text "real_ip")
if not real_ip_map_re.search(content):
    content = insert_after_http_open(content, real_ip_map)
    changed = True

# Adaugă map $ddos_blocked după map-ul $real_ip, dacă nu există
if not ddos_map_re.search(content):
    real_end = find_real_ip_map_end(content)
    if real_end != -1:
        content = content[:real_end] + "\n" + ddos_map + content[real_end:]
    else:
        content = insert_after_http_open(content, ddos_map)
    changed = True

# Adaugă map pentru țară din Cloudflare (CF-IPCountry)
if not country_map_re.search(content):
    content = insert_after_http_open(content, country_map)
    changed = True

# Adaugă logging JSON pentru dashboard (ip/method/path/status)
if not ddos_log_re.search(content):
    content = insert_after_http_open(content, ddos_log_format)
    changed = True
else:
    # Upgrade pentru formatele vechi care aveau country="-"
    new = re.sub(
        r'(?m)^(\s*log_format\s+ddos_json\s+escape=json\s+\'\{)"ip":"\$real_ip","country":"-","method":"\$request_method","path":"\$uri","status":"\$status"(\}\'\s*;)\s*$',
        r'\1"ip":"$real_ip","country":"$ddos_country","method":"$request_method","path":"$uri","status":"$status"\2',
        content
    )
    if new != content:
        content = new
        changed = True

# Forțează access_log pe stdout (altfel Loki nu vede traficul dacă logul rămâne în fișier)
new = re.sub(
    r'(?m)^(\s*)access_log\s+/var/log/nginx/access\.log\s+main(\s+if=[^;]+)?;',
    r'\1access_log /dev/stdout ddos_json\2;',
    content
)
if new != content:
    content = new
    changed = True

# Adaugă if ddos_blocked în server dacă nu există (map-ul poate exista deja)
if not re.search(r'(?m)^\s*if\s*\(\s*\$ddos_blocked\s*\)\s*\{', content):
    server_open = content.find('server {')
    if server_open != -1:
        # Găsește prima linie după { în server
        brace = content.find('{', server_open) + 1
        nl = content.find('\n', brace)
        inject = """
  if ($ddos_blocked) {
    return 403;
  }
"""
        content = content[:nl] + inject + content[nl:]
        changed = True

# Fix de migrare pentru rulări vechi care au scris \$variabile în .conf
for bad, good in [
    ("\\$ddos_blocked", "$ddos_blocked"),
    ("\\$ddos_ray", "$ddos_ray"),
    ("\\$ddos_country", "$ddos_country"),
    ("\\$real_ip", "$real_ip"),
    ("\\$request_method", "$request_method"),
    ("\\$uri", "$uri"),
    ("\\$status", "$status"),
    ("\\$http_cf_ray", "$http_cf_ray"),
    ("\\$http_cf_ipcountry", "$http_cf_ipcountry"),
    ("\\$http_cf_connecting_ip", "$http_cf_connecting_ip"),
    ("\\$remote_addr", "$remote_addr"),
]:
    if bad in content:
        content = content.replace(bad, good)
        changed = True

# Dedupe blocuri injectate de rulări multiple
def keep_first(pattern, text):
    seen = False
    def _repl(m):
        nonlocal seen
        if seen:
            return ""
        seen = True
        return m.group(0)
    return re.sub(pattern, _repl, text)

for pattern in [
    r'(?ms)^\s*map\s+\$http_cf_connecting_ip\s+\$real_ip\s*\{.*?^\s*\}\s*\n?',
    r'(?ms)^\s*map\s+\$real_ip\s+\$ddos_blocked\s*\{.*?^\s*\}\s*\n?',
    r'(?ms)^\s*map\s+\$http_cf_ipcountry\s+\$ddos_country\s*\{.*?^\s*\}\s*\n?',
    r'(?ms)^\s*map\s+\$http_cf_ray\s+\$ddos_ray\s*\{.*?^\s*\}\s*\n?',
    r'(?m)^\s*log_format\s+ddos_json\s+.*;\s*\n?',
    r'(?m)^\s*access_log\s+/dev/stdout\s+ddos_json(?:\s+if=[^;]+)?;\s*\n?',
]:
    new_content = keep_first(pattern, content)
    if new_content != content:
        content = new_content
        changed = True

open(os.environ["APP_NGINX_CONF"], "w").write(content)

repo_dir = Path(os.environ["APP_REPO_DIR"])
for conf in repo_dir.rglob("*.conf"):
    try:
        txt = conf.read_text()
    except Exception:
        continue
    old = txt
    for bad, good in [
        ("\\$ddos_blocked", "$ddos_blocked"),
        ("\\$ddos_ray", "$ddos_ray"),
        ("\\$ddos_country", "$ddos_country"),
        ("\\$real_ip", "$real_ip"),
        ("\\$request_method", "$request_method"),
        ("\\$uri", "$uri"),
        ("\\$status", "$status"),
        ("\\$http_cf_ray", "$http_cf_ray"),
        ("\\$http_cf_ipcountry", "$http_cf_ipcountry"),
        ("\\$http_cf_connecting_ip", "$http_cf_connecting_ip"),
        ("\\$remote_addr", "$remote_addr"),
    ]:
        txt = txt.replace(bad, good)
    if txt != old:
        conf.write_text(txt)
        changed = True

print("nginx.conf actualizat" if changed else "nginx.conf deja OK")
PYEOF
    success "nginx.conf actualizat"

    python3 - <<PYEOF
import re
content = open("$DOCKERFILE").read()
changed = False

if "docker-entrypoint.sh" not in content:
    cmd_idx = content.rfind('\nCMD ')
    content = content[:cmd_idx] + '\nCOPY --chmod=755 docker-entrypoint.sh /docker-entrypoint.sh\n' + content[cmd_idx:]
    changed = True
else:
    new = re.sub(
        r'COPY docker-entrypoint\.sh /docker-entrypoint\.sh\s*\nRUN chmod \+x /docker-entrypoint\.sh',
        'COPY --chmod=755 docker-entrypoint.sh /docker-entrypoint.sh',
        content
    )
    if new != content:
        content = new; changed = True

new = re.sub(r'CMD\s+\[.*nginx.*\]', 'CMD ["/docker-entrypoint.sh"]', content)
if new != content:
    content = new; changed = True

open("$DOCKERFILE", "w").write(content)
print("Dockerfile actualizat" if changed else "Dockerfile deja OK")
PYEOF
    success "Dockerfile actualizat"
    ;;

  # --------------------------------------------------------------------------
  nextjs)
  # --------------------------------------------------------------------------
    MIDDLEWARE=$(find "$CLONE_DIR" -name "middleware.ts" | head -1)
    if [ -z "$MIDDLEWARE" ]; then
      NEXT_ROOT=$(find "$CLONE_DIR" -name "package.json" -maxdepth 4 | head -1 | xargs dirname 2>/dev/null || true)
      [ -z "$NEXT_ROOT" ] && NEXT_ROOT="$CLONE_DIR"
      MIDDLEWARE="$NEXT_ROOT/middleware.ts"
      cat > "$MIDDLEWARE" <<'MEOF'
import { NextRequest, NextResponse } from "next/server";

export function middleware(_request: NextRequest) {
  return NextResponse.next();
}
MEOF
      success "middleware.ts creat"
    fi

    python3 - <<PYEOF
content = open("$MIDDLEWARE").read()

if "isBlockedIp" in content or "ddos-agent" in content:
    print("DDoS block deja prezent — sărit")
else:
    ddos_block = '''// ---------------------------------------------------------------------------
// DDoS blocklist (fetched from ddos-agent, cached 15s)
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
    const res = await fetch(DDOS_AGENT_URL, { cache: "no-store", signal: AbortSignal.timeout(1500) });
    if (res.ok) {
      const data = await res.json();
      _blockedIpCache = new Set(data.items ?? []);
      _blockedIpCacheExpiresAt = now + 15_000;
    }
  } catch { /* fail silently */ }
  return _blockedIpCache.has(ip);
}

function logTraffic(ip: string, method: string, path: string, status: number, country = "-"): void {
  try {
    console.log(JSON.stringify({ ip, country, method, path, status }));
  } catch { /* ignore logging failures */ }
}

'''
    lines = content.split("\n")
    last_import = max((i for i, l in enumerate(lines) if l.startswith("import ")), default=0)
    lines.insert(last_import + 1, ddos_block)
    content = "\n".join(lines)

    content = content.replace("export function middleware(", "export async function middleware(")

    mw_start = content.find("export async function middleware(")
    body_start = content.find("{", mw_start) + 1
    nl = content.find("\n", body_start)
    check = """
  const _ip = request.headers.get("cf-connecting-ip")?.trim() ||
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || "unknown";
  const _country = request.headers.get("cf-ipcountry")?.trim() || "-";
  if (await isBlockedIp(_ip)) {
    logTraffic(_ip, request.method, request.nextUrl.pathname, 403, _country);
    if (request.nextUrl.pathname.startsWith("/api/"))
      return NextResponse.json({ error: "Forbidden" }, { status: 403 });
    return new NextResponse("Forbidden", { status: 403 });
  }
  logTraffic(_ip, request.method, request.nextUrl.pathname, 200, _country);
"""
    content = content[:nl] + check + content[nl:]
    open("$MIDDLEWARE", "w").write(content)
    print("middleware.ts actualizat")
PYEOF
    success "middleware.ts actualizat"
    ;;

  # --------------------------------------------------------------------------
  # Tipuri ne-suportate — creează fișier cu instrucțiuni
  # --------------------------------------------------------------------------
  *)
    warn "Tip '${APP_TYPE}' — nu pot modifica automat codul."
    cat > "$CLONE_DIR/DDOS_INTEGRATION.md" <<MDEOF
# Integrare DDoS Protection

Endpoint blocklist:
- Plain text: \`http://ddos-agent.ddos-protection.svc.cluster.local:8080/blocklist.txt\`
- JSON:       \`http://ddos-agent.ddos-protection.svc.cluster.local:8080/blocklist\`

Logică: verifică IP-ul din \`CF-Connecting-IP\` la fiecare request.
Dacă e în blocklist → 403. Refresh cache la 15s.

Format minim recomandat pentru logs (JSON pe stdout), necesar pentru dashboard:
\`\`\`json
{"ip":"1.2.3.4","country":"RO","method":"GET","path":"/api/health","status":200}
\`\`\`
MDEOF
    success "DDOS_INTEGRATION.md creat cu instrucțiuni"
    ;;
esac

# =============================================================================
# Pasul 4: Commit + push repo aplicație
# =============================================================================
step "Push repo aplicație"

cd "$CLONE_DIR"
git config user.email "ddos-script@local" 2>/dev/null || true
git config user.name "ddos-script" 2>/dev/null || true

if git diff --quiet && git diff --staged --quiet; then
  info "Nu sunt modificări — repo-ul era deja integrat"
else
  git add -A
  git commit -m "feat: integrate DDoS blocklist protection via ddos-agent"
  git push && success "Repo aplicație pushuit → ArgoCD va face build + deploy" || \
    error "Push eșuat — verifică permisiunile pentru $APP_REPO_URL"
fi

rm -rf "$CLONE_DIR"

# =============================================================================
# Pasul 5: Infra — namespace + network policy + configmap (GitOps)
# =============================================================================
step "Infra: network policy + configmap"

[ -f "$CONFIGMAP" ] || error "Nu găsesc $CONFIGMAP"
[ -d "$NETPOL_REPO" ] || error "Nu găsesc $NETPOL_REPO"

# Detectare namespace din ArgoCD
info "Caut namespace-ul în ArgoCD ..."
ARGO_APPS_JSON=$($KUBECTL get applications -n argocd -o json 2>/dev/null || true)
NAMESPACE=""
if [ -n "$ARGO_APPS_JSON" ]; then
  NAMESPACE=$(echo "$ARGO_APPS_JSON" | python3 -c "
import sys, json, re
apps = json.load(sys.stdin).get('items', [])
app_url = '$APP_REPO_URL_NORM'
gitops_url = '$GITOPS_REPO_URL_NORM'
def norm(url):
    return re.sub(r'\.git$', '', (url or '').rstrip('/'))
for a in apps:
    spec = a.get('spec', {})
    repos = []
    source_repo = spec.get('source', {}).get('repoURL', '')
    if source_repo:
        repos.append(norm(source_repo))
    for s in spec.get('sources', []) or []:
        repo = norm(s.get('repoURL', ''))
        if repo:
            repos.append(repo)
    if app_url in repos or (gitops_url and gitops_url in repos):
        ns = spec.get('destination', {}).get('namespace', '')
        if ns:
            print(ns)
            break
" 2>/dev/null || true)
else
  warn "Nu pot citi aplicațiile ArgoCD prin SSH/kubectl (verifică accesul)."
fi

if [ -n "$NAMESPACE" ]; then
  success "Namespace din ArgoCD: $NAMESPACE"
else
  warn "Nu am găsit în ArgoCD."
  read -rp "  Namespace Kubernetes: " NAMESPACE
  [ -z "$NAMESPACE" ] && error "Namespace-ul nu poate fi gol."
fi

# Detectare label din cluster
info "Detectez label-ul în namespace '$NAMESPACE' ..."
PODS_JSON=$($KUBECTL get pods -n "$NAMESPACE" -o json 2>/dev/null || true)
DETECTED_LABELS=""
if [ -n "$PODS_JSON" ]; then
  DETECTED_LABELS=$(echo "$PODS_JSON" | python3 -c "
import sys, json
keys = ['app', 'app.kubernetes.io/name', 'app.kubernetes.io/instance', 'k8s-app']
items = json.load(sys.stdin).get('items', [])
pairs = set()
for pod in items:
    labels = pod.get('metadata', {}).get('labels', {}) or {}
    for k in keys:
        v = labels.get(k, '').strip()
        if v:
            pairs.add(f'{k}={v}')
print('\n'.join(sorted(pairs)))
" 2>/dev/null || true)
else
  warn "Nu pot lista pod-urile din namespace-ul '$NAMESPACE' (verifică accesul)."
fi
LABEL_COUNT=$(echo "$DETECTED_LABELS" | grep -c . 2>/dev/null || true)

if [ -z "$DETECTED_LABELS" ]; then
  warn "Nu am găsit label automat (app/app.kubernetes.io/name/app.kubernetes.io/instance)."
  read -rp "  Label key [app]: " APP_LABEL_KEY
  APP_LABEL_KEY="${APP_LABEL_KEY:-app}"
  read -rp "  Label value (${APP_LABEL_KEY}=?): " APP_LABEL
elif [ "$LABEL_COUNT" -eq 1 ]; then
  APP_LABEL_KEY="${DETECTED_LABELS%%=*}"
  APP_LABEL="${DETECTED_LABELS#*=}"
  success "Label detectat: ${APP_LABEL_KEY}=$APP_LABEL"
else
  echo "  Labels găsite:"
  i=1
  while IFS= read -r lbl; do echo "    $i) $lbl"; i=$((i+1)); done <<< "$DETECTED_LABELS"
  read -rp "  Alege [1-$((i-1))]: " CHOICE
  CHOSEN_LABEL=$(echo "$DETECTED_LABELS" | sed -n "${CHOICE}p")
  APP_LABEL_KEY="${CHOSEN_LABEL%%=*}"
  APP_LABEL="${CHOSEN_LABEL#*=}"
  success "Label ales: ${APP_LABEL_KEY}=$APP_LABEL"
fi
[ -z "$APP_LABEL" ] && error "Label-ul nu poate fi gol."
[ -z "$APP_LABEL_KEY" ] && error "Label key nu poate fi gol."

# Actualizează configmap
CURRENT_NS=$(grep 'LOKI_NAMESPACES:' "$CONFIGMAP" | sed 's/.*"\(.*\)".*/\1/')
if echo "$CURRENT_NS" | grep -qE "(^|[|])${NAMESPACE}([|]|$)"; then
  info "Namespace deja în LOKI_NAMESPACES — sărit"
else
  NEW_NS="${CURRENT_NS}|${NAMESPACE}"
  CURRENT_PROT=$(grep 'PROTECTED_NAMESPACES:' "$CONFIGMAP" | sed 's/.*"\(.*\)".*/\1/')
  NEW_PROT="${CURRENT_PROT}|${NAMESPACE}"
  python3 - <<PYEOF
content = open("$CONFIGMAP").read()
content = content.replace('LOKI_NAMESPACES: "$CURRENT_NS"', 'LOKI_NAMESPACES: "$NEW_NS"')
content = content.replace('PROTECTED_NAMESPACES: "$CURRENT_PROT"', 'PROTECTED_NAMESPACES: "$NEW_PROT"')
open("$CONFIGMAP", "w").write(content)
PYEOF
  cd "$CONFIGMAP_GIT_ROOT"
  git config user.email "ddos-script@local" 2>/dev/null || true
  git config user.name "ddos-script" 2>/dev/null || true
  git add "$CONFIGMAP_GIT_ADD_PATH"
  git commit -m "feat: add $NAMESPACE to monitored namespaces"
  git push && success "ConfigMap pushuit ($CONFIGMAP_REPO_LABEL) → ArgoCD sync" || \
    warn "Push eșuat — fă manual: cd $CONFIGMAP_GIT_ROOT && git push"
fi

# Creează network policy
NETPOL_DIR="$NETPOL_REPO/$NAMESPACE"
mkdir -p "$NETPOL_DIR"

LAST_NUM=$(ls "$NETPOL_DIR"/*.yaml 2>/dev/null | xargs -I{} basename {} | grep -oE '^[0-9]+' | sort -n | tail -1 || true)
NETPOL_CHANGED=0

if ls "$NETPOL_DIR"/*ddos-agent-egress* &>/dev/null; then
  info "Cilium policy ddos-agent-egress există deja — sărit"
else
  NEXT_NUM=$(printf "%02d" $(( ${LAST_NUM:-0} + 1 )))
  LAST_NUM="$NEXT_NUM"
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
      ${APP_LABEL_KEY}: ${APP_LABEL}
  egress:
  - toEntities:
    - host
    - remote-node
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
EOF
  NETPOL_CHANGED=1
fi

# Hardening strict pentru employee-leave: asigură egress DNS + ddos-agent service
if [ "$NAMESPACE" = "employee-leave" ]; then
  if ls "$NETPOL_DIR"/*ddos-agent-dns-egress* &>/dev/null; then
    info "Policy employee-leave pentru DNS + ddos-agent există deja — sărit"
  else
    NEXT_NUM=$(printf "%02d" $(( ${LAST_NUM:-0} + 1 )))
    LAST_NUM="$NEXT_NUM"
    NS_POLICY_FILE="$NETPOL_DIR/${NEXT_NUM}-allow-ddos-agent-dns-egress.yaml"
    cat > "$NS_POLICY_FILE" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ddos-agent-dns-egress
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      ${APP_LABEL_KEY}: ${APP_LABEL}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ddos-protection
      podSelector:
        matchLabels:
          app: ddos-agent
    ports:
    - protocol: TCP
      port: 8080
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
EOF
    NETPOL_CHANGED=1
  fi
fi

if [ "$NETPOL_CHANGED" -eq 1 ]; then
  cd "$NETPOL_REPO"
  git add "$NETPOL_DIR"
  git commit -m "feat($NAMESPACE): allow ddos-agent egress (and DNS for employee-leave)"
  git push && success "k8s-network-policies pushuit → ArgoCD sync" || \
    warn "Push eșuat — fă manual: cd $NETPOL_REPO && git push"
else
  info "Nu sunt network policy-uri noi de push"
fi

# =============================================================================
# Sumar
# =============================================================================
step "Sumar final"
echo ""
echo -e "  Repo:       ${GREEN}$APP_REPO_URL${NC}"
echo -e "  GitOps:     ${GREEN}${GITOPS_REPO_URL:-<ne-setat>}${NC}"
echo -e "  Namespace:  ${GREEN}$NAMESPACE${NC}"
echo -e "  App label:  ${GREEN}${APP_LABEL_KEY}=$APP_LABEL${NC}"
echo -e "  Tip app:    ${GREEN}$APP_TYPE${NC}"
echo -e "  ConfigMap:  ${GREEN}$CONFIGMAP${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Repo aplicație modificat + pushuit"
echo -e "  ${GREEN}✓${NC} configmap.yaml actualizat + pushuit în repo-ul lui"
echo -e "  ${GREEN}✓${NC} CiliumNetworkPolicy creat + pushuit"
echo ""
echo -e "  ${YELLOW}ArgoCD va:${NC}"
echo "  → face build imaginii noi + deploy aplicație"
echo "  → sincroniza repo-ul cu configmap ($CONFIGMAP_REPO_LABEL)"
echo "  → sincroniza k8s-network-policies (network policy)"
echo ""

[ -n "$GITOPS_CLONE_DIR" ] && rm -rf "$GITOPS_CLONE_DIR"
