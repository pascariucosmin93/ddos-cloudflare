#!/bin/bash
# =============================================================================
# add-app-json-logging.sh <app-repo-url>
# Scope: doar aplicația (fără GitOps/configmap/networkpolicy)
#        adaugă logging JSON pentru Grafana/Loki: ip,country,ray,method,path,status
# =============================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }
step()    { echo -e "\n${CYAN}══ $* ${NC}"; }

step "Clone repo aplicație"
if [ -n "$1" ]; then
  APP_REPO_URL="$1"
else
  read -rp "  URL repo aplicație: " APP_REPO_URL
  [ -z "$APP_REPO_URL" ] && error "URL-ul nu poate fi gol."
fi

CLONE_DIR=$(mktemp -d)
info "Clonez $APP_REPO_URL ..."
git clone "$APP_REPO_URL" "$CLONE_DIR" || error "Clone eșuat"
success "Repo clonat"

step "Detectare tip aplicație"
APP_TYPE="unknown"
if find "$CLONE_DIR" -name "nginx.conf" | grep -q .; then
  APP_TYPE="nginx"
elif find "$CLONE_DIR" -name "middleware.ts" | grep -q .; then
  APP_TYPE="nextjs"
elif find "$CLONE_DIR" -maxdepth 4 -name "package.json" | xargs grep -l '"next"' 2>/dev/null | grep -q .; then
  APP_TYPE="nextjs"
fi
success "Tip detectat: $APP_TYPE"

step "Patch logging JSON"
case "$APP_TYPE" in
  nginx)
    NGINX_CONF=$(find "$CLONE_DIR" -name "nginx.conf" | head -1)
    [ -z "$NGINX_CONF" ] && error "Nu găsesc nginx.conf"

    APP_NGINX_CONF="$NGINX_CONF" APP_REPO_DIR="$CLONE_DIR" python3 - <<'PYEOF'
import os
import re
from pathlib import Path
path = os.environ["APP_NGINX_CONF"]
content = open(path).read()
changed = False

country_map = """map $http_cf_ipcountry $ddos_country {
  ""      "-";
  default $http_cf_ipcountry;
}

"""
ray_map = """map $http_cf_ray $ddos_ray {
  ""      "-";
  default $http_cf_ray;
}

"""
json_fmt = """log_format ddos_json escape=json '{"ip":"$real_ip","country":"$ddos_country","ray":"$ddos_ray","method":"$request_method","path":"$uri","status":"$status"}';
access_log /dev/stdout ddos_json;

"""
real_ip_map = """map $http_cf_connecting_ip $real_ip {
  ""      $remote_addr;
  default $http_cf_connecting_ip;
}

"""

http_open_re = re.compile(r'(?m)^\\s*http\\s*\\{')
def insert_after_http_open(text, block):
    m = http_open_re.search(text)
    if not m:
        return block + text
    nl = text.find("\\n", m.end())
    if nl == -1:
        return text + "\\n" + block
    return text[:nl+1] + block + text[nl+1:]

checks = [
    (re.compile(r'(?m)^\\s*map\\s+\\$http_cf_connecting_ip\\s+\\$real_ip\\s*\\{'), real_ip_map),
    (re.compile(r'(?m)^\\s*map\\s+\\$http_cf_ipcountry\\s+\\$ddos_country\\s*\\{'), country_map),
    (re.compile(r'(?m)^\\s*map\\s+\\$http_cf_ray\\s+\\$ddos_ray\\s*\\{'), ray_map),
    (re.compile(r'(?m)^\\s*log_format\\s+ddos_json\\s+'), json_fmt),
]
for rgx, block in checks:
    if not rgx.search(content):
        content = insert_after_http_open(content, block)
        changed = True

# Upgrade format vechi (country "-" si/sau fara ray)
old_fmt = "log_format ddos_json escape=json '{\"ip\":\"$real_ip\",\"country\":\"-\",\"method\":\"$request_method\",\"path\":\"$uri\",\"status\":\"$status\"}';"
new_fmt = "log_format ddos_json escape=json '{\"ip\":\"$real_ip\",\"country\":\"$ddos_country\",\"ray\":\"$ddos_ray\",\"method\":\"$request_method\",\"path\":\"$uri\",\"status\":\"$status\"}';"
if old_fmt in content:
    content = content.replace(old_fmt, new_fmt)
    changed = True

# Fix de migrare: curăță variabilele nginx rămase escapate (ex: \$ddos_ray)
for bad, good in [
    ("\\$ddos_blocked", "$ddos_blocked"),
    ("\\$ddos_ray", "$ddos_ray"),
    ("\\$ddos_country", "$ddos_country"),
    ("\\$real_ip", "$real_ip"),
    ("\\$request_method", "$request_method"),
    ("\\$uri", "$uri"),
    ("\\$status", "$status"),
    ("\\$http_cf_ipcountry", "$http_cf_ipcountry"),
    ("\\$http_cf_ray", "$http_cf_ray"),
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

# Forțează access_log în stdout
new = re.sub(
    r'(?m)^(\\s*)access_log\\s+/var/log/nginx/access\\.log\\s+main(\\s+if=[^;]+)?;',
    r'\\1access_log /dev/stdout ddos_json\\2;',
    content
)
if new != content:
    content = new
    changed = True

open(path, "w").write(content)

# Curăță și orice alte .conf (ex: conf.d/default.conf) care au rămas cu \$variabila
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
        ("\\$http_cf_ipcountry", "$http_cf_ipcountry"),
        ("\\$http_cf_ray", "$http_cf_ray"),
        ("\\$http_cf_connecting_ip", "$http_cf_connecting_ip"),
        ("\\$remote_addr", "$remote_addr"),
    ]:
        txt = txt.replace(bad, good)
    if txt != old:
        conf.write_text(txt)
        changed = True

print("nginx.conf actualizat" if changed else "nginx.conf deja OK")
PYEOF
    success "nginx logging JSON activat"
    ;;

  nextjs)
    MIDDLEWARE=$(find "$CLONE_DIR" -name "middleware.ts" | head -1)
    if [ -z "$MIDDLEWARE" ]; then
      NEXT_ROOT=$(find "$CLONE_DIR" -maxdepth 4 -name "package.json" | head -1 | xargs dirname 2>/dev/null || true)
      [ -z "$NEXT_ROOT" ] && NEXT_ROOT="$CLONE_DIR"
      MIDDLEWARE="$NEXT_ROOT/middleware.ts"
      cat > "$MIDDLEWARE" <<'MEOF'
import { NextRequest, NextResponse } from "next/server";
export function middleware(_request: NextRequest) { return NextResponse.next(); }
MEOF
      success "middleware.ts creat"
    fi

    python3 - <<PYEOF
path = "$MIDDLEWARE"
content = open(path).read()
changed = False

if "console.log(JSON.stringify({" not in content:
    block = """
function _logTraffic(request: NextRequest, status: number): void {
  const ip = request.headers.get("cf-connecting-ip")?.trim() ||
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || "unknown";
  const country = request.headers.get("cf-ipcountry")?.trim() || "-";
  const ray = request.headers.get("cf-ray")?.trim() || "-";
  try {
    console.log(JSON.stringify({ ip, country, ray, method: request.method, path: request.nextUrl.pathname, status }));
  } catch {}
}
"""
    lines = content.split("\\n")
    last_import = max((i for i,l in enumerate(lines) if l.startswith("import ")), default=0)
    lines.insert(last_import + 1, block)
    content = "\\n".join(lines)
    changed = True

if "export async function middleware(" not in content and "export function middleware(" in content:
    content = content.replace("export function middleware(", "export async function middleware(")
    changed = True

if "_logTraffic(request, 200);" not in content:
    needle = "return NextResponse.next();"
    if needle in content:
        content = content.replace(needle, "_logTraffic(request, 200);\\n  " + needle, 1)
        changed = True

open(path, "w").write(content)
print("middleware.ts actualizat" if changed else "middleware.ts deja OK")
PYEOF
    success "nextjs logging JSON activat"
    ;;

  *)
    warn "Tip nesuportat pentru patch automat."
    cat > "$CLONE_DIR/JSON_LOGGING.md" <<'EOF'
# JSON Logging Contract (Grafana/Loki)
Log line (stdout):
{"ip":"1.2.3.4","country":"RO","ray":"<cf-ray-or->","method":"GET","path":"/api/x","status":200}

Headers recomandate:
- CF-Connecting-IP
- CF-IPCountry
- CF-Ray
EOF
    success "Creat JSON_LOGGING.md"
    ;;
esac

step "Commit + push"
cd "$CLONE_DIR"
git config user.email "ddos-script@local" 2>/dev/null || true
git config user.name "ddos-script" 2>/dev/null || true

if git diff --quiet && git diff --staged --quiet; then
  info "Nu sunt modificări de push."
else
  git add -A
  git commit -m "feat: add JSON traffic logging (ip/country/ray/method/path/status)"
  git push || error "Push eșuat"
  success "Push făcut"
fi

rm -rf "$CLONE_DIR"
success "Gata"
