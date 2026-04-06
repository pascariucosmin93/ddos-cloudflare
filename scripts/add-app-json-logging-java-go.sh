#!/bin/bash
# =============================================================================
# add-app-json-logging-java-go.sh <app-repo-url>
# Scope: aplicații Java/Go
# Adaugă logging JSON compatibil Loki/Grafana:
# {"ip":"...","country":"...","ray":"...","method":"...","path":"...","status":200}
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

step "Detectare stack"
APP_TYPE="unknown"
if find "$CLONE_DIR" -maxdepth 4 -name "go.mod" | grep -q .; then
  APP_TYPE="go"
elif find "$CLONE_DIR" -maxdepth 4 \( -name "pom.xml" -o -name "build.gradle" -o -name "build.gradle.kts" \) | grep -q .; then
  APP_TYPE="java"
fi
success "Tip detectat: $APP_TYPE"

case "$APP_TYPE" in
  java)
    step "Patch Java"
    JAVA_SRC="$CLONE_DIR/src/main/java"
    [ -d "$JAVA_SRC" ] || error "Nu găsesc src/main/java"

    JAVA_FILE=$(find "$JAVA_SRC" -name "*Application.java" | head -1)
    [ -z "$JAVA_FILE" ] && JAVA_FILE=$(find "$JAVA_SRC" -name "*.java" | head -1)
    [ -z "$JAVA_FILE" ] && error "Nu găsesc fișiere Java"

    BASE_PACKAGE=$(grep -E '^\s*package\s+' "$JAVA_FILE" | head -1 | sed -E 's/^\s*package\s+([a-zA-Z0-9_.]+)\s*;.*/\1/')
    [ -z "$BASE_PACKAGE" ] && error "Nu pot detecta package-ul Java din $JAVA_FILE"

    PKG_PATH=$(echo "$BASE_PACKAGE" | tr '.' '/')
    TARGET_DIR="$JAVA_SRC/$PKG_PATH/observability"
    mkdir -p "$TARGET_DIR"
    FILTER_FILE="$TARGET_DIR/JsonTrafficLoggingFilter.java"

    cat > "$FILTER_FILE" <<EOF
package ${BASE_PACKAGE}.observability;

import java.io.IOException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

@Component
@Order(Ordered.LOWEST_PRECEDENCE)
public class JsonTrafficLoggingFilter extends OncePerRequestFilter {
  private static final Logger log = LoggerFactory.getLogger(JsonTrafficLoggingFilter.class);

  @Override
  protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
      throws ServletException, IOException {
    try {
      filterChain.doFilter(request, response);
    } finally {
      final String ip = firstNonEmpty(
          firstHeaderValue(request, "CF-Connecting-IP"),
          firstHeaderValue(request, "X-Forwarded-For"),
          request.getRemoteAddr()
      );
      final String country = firstNonEmpty(request.getHeader("CF-IPCountry"), "-");
      final String ray = firstNonEmpty(request.getHeader("CF-Ray"), "-");
      final String method = firstNonEmpty(request.getMethod(), "-");
      final String path = firstNonEmpty(request.getRequestURI(), "-");
      final int status = response.getStatus();

      log.info(
          "{{\"ip\":\"{}\",\"country\":\"{}\",\"ray\":\"{}\",\"method\":\"{}\",\"path\":\"{}\",\"status\":{}}}",
          escape(ip), escape(country), escape(ray), escape(method), escape(path), status
      );
    }
  }

  private static String firstHeaderValue(HttpServletRequest req, String name) {
    final String v = req.getHeader(name);
    if (v == null || v.isBlank()) return "";
    final int comma = v.indexOf(',');
    return comma >= 0 ? v.substring(0, comma).trim() : v.trim();
  }

  private static String firstNonEmpty(String... values) {
    for (String v : values) {
      if (v != null && !v.isBlank()) return v.trim();
    }
    return "-";
  }

  private static String escape(String s) {
    return s.replace("\\\\", "\\\\\\\\").replace("\"", "\\\\\"");
  }
}
EOF
    success "Creat $FILTER_FILE"

    cat > "$CLONE_DIR/JSON_LOGGING_JAVA.md" <<'EOF'
# Java JSON Logging
Filter adăugat: `JsonTrafficLoggingFilter` (Spring Boot / Servlet).
Format log: `{"ip":"...","country":"...","ray":"...","method":"...","path":"...","status":200}`
EOF
    success "Creat JSON_LOGGING_JAVA.md"
    ;;

  go)
    step "Patch Go"
    OBS_DIR="$CLONE_DIR/internal/observability"
    mkdir -p "$OBS_DIR"

    cat > "$OBS_DIR/logging_common.go" <<'EOF'
package observability

import (
	"encoding/json"
	"log"
	"strings"
)

func firstHeaderValue(header string) string {
	header = strings.TrimSpace(header)
	if header == "" {
		return ""
	}
	parts := strings.Split(header, ",")
	return strings.TrimSpace(parts[0])
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return "-"
}

func logJSON(ip, country, ray, method, path string, status int) {
	payload := map[string]any{
		"ip":      firstNonEmpty(ip),
		"country": firstNonEmpty(country, "-"),
		"ray":     firstNonEmpty(ray, "-"),
		"method":  firstNonEmpty(method, "-"),
		"path":    firstNonEmpty(path, "-"),
		"status":  status,
	}
	b, err := json.Marshal(payload)
	if err != nil {
		return
	}
	log.Println(string(b))
}
EOF

    cat > "$OBS_DIR/logging_http.go" <<'EOF'
package observability

import "net/http"

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func JSONTrafficLogger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)

		ip := firstNonEmpty(
			firstHeaderValue(r.Header.Get("CF-Connecting-IP")),
			firstHeaderValue(r.Header.Get("X-Forwarded-For")),
			r.RemoteAddr,
		)
		country := firstNonEmpty(r.Header.Get("CF-IPCountry"), "-")
		ray := firstNonEmpty(r.Header.Get("CF-Ray"), "-")
		logJSON(ip, country, ray, r.Method, r.URL.Path, rec.status)
	})
}
EOF

    GO_MOD=$(find "$CLONE_DIR" -maxdepth 4 -name "go.mod" | head -1)
    if [ -n "$GO_MOD" ] && grep -q 'github.com/gin-gonic/gin' "$GO_MOD"; then
      cat > "$OBS_DIR/logging_gin.go" <<'EOF'
package observability

import "github.com/gin-gonic/gin"

func GinJSONTrafficLogger() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Next()
		ip := firstNonEmpty(
			firstHeaderValue(c.GetHeader("CF-Connecting-IP")),
			firstHeaderValue(c.GetHeader("X-Forwarded-For")),
			c.ClientIP(),
		)
		country := firstNonEmpty(c.GetHeader("CF-IPCountry"), "-")
		ray := firstNonEmpty(c.GetHeader("CF-Ray"), "-")
		logJSON(ip, country, ray, c.Request.Method, c.Request.URL.Path, c.Writer.Status())
	}
}
EOF
      success "Creat middleware Gin"
    fi

    cat > "$CLONE_DIR/JSON_LOGGING_GO.md" <<'EOF'
# Go JSON Logging
Fișiere adăugate în `internal/observability/`.

Net/http:
```go
mux := http.NewServeMux()
// routes...
log.Fatal(http.ListenAndServe(":8080", observability.JSONTrafficLogger(mux)))
```

Gin (dacă folosești gin):
```go
r := gin.Default()
r.Use(observability.GinJSONTrafficLogger())
```
EOF
    success "Creat JSON_LOGGING_GO.md"
    ;;

  *)
    warn "Repo-ul nu pare Java/Go. Nu fac patch."
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
  git commit -m "feat: add JSON traffic logging for ${APP_TYPE} apps"
  git push || error "Push eșuat"
  success "Push făcut"
fi

rm -rf "$CLONE_DIR"
success "Gata"
