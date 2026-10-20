#!/usr/bin/env bash
# Kong OSS release — clean install.
#
# 1. validates prerequisites (docker + compose v2, curl, python3)
# 2. prepares .env (auto-generates a strong KONG_PG_PASSWORD when missing)
# 3. validates the compose file, builds and starts the stack
# 4. waits for PostgreSQL and Kong to become healthy
# 5. applies the idempotent Admin API configuration
#
# Safe to re-run: everything is an upsert / idempotent start.
source "$(dirname "$0")/_common.sh"

require_cmd docker
require_cmd curl
require_cmd python3
docker compose version >/dev/null 2>&1 || die "docker compose v2 is not available"

# ------------------------------------------------------------- .env ----
if [ ! -f "$ROOT_DIR/.env" ]; then
  cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
  if command -v openssl >/dev/null 2>&1; then
    PW="$(openssl rand -hex 24)"
  else
    PW="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
  sed -i.bak "s/^KONG_PG_PASSWORD=.*/KONG_PG_PASSWORD=$PW/" "$ROOT_DIR/.env"
  rm -f "$ROOT_DIR/.env.bak"
  chmod 600 "$ROOT_DIR/.env"
  log ".env created (KONG_PG_PASSWORD auto-generated, file mode 600)"
else
  # refuse to run with the example placeholder password
  if grep -q '^KONG_PG_PASSWORD=change-me' "$ROOT_DIR/.env"; then
    die ".env still contains the placeholder KONG_PG_PASSWORD — set a strong random value"
  fi
  log ".env found"
fi

# The first source of _common.sh ran BEFORE .env existed on a fresh
# install, so the shell variables were already defaulted (project name
# kong-gw-oss, ports 18080/18001). Re-source now so the values from
# .env (COMPOSE_PROJECT_NAME, KONG_PROXY_PORT, KONG_ADMIN_PORT, ...)
# take effect for this run — .env is loaded with set -a, so it
# overwrites the earlier defaults.
# shellcheck disable=SC1090
source "$(dirname "$0")/_common.sh"

log "=== Kong OSS setup (project: $COMPOSE_PROJECT_NAME, proxy :$KONG_PROXY_PORT, admin :$KONG_ADMIN_PORT) ==="

# -------------------------------------------------------- compose ------
compose config -q >/dev/null || die "docker compose config validation failed"

# Port pre-flight: the two loopback ports must be free on this host —
# except when held by our own kong container (re-runs are idempotent,
# so the existing stack's own bindings are allowed).
for p in "$KONG_PROXY_PORT" "$KONG_ADMIN_PORT"; do
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$"; then
      if docker port "$KONG_CONTAINER" 2>/dev/null | grep -Eq "[:.]${p}$"; then
        log "port $p already held by $KONG_CONTAINER (re-run — continuing)"
        continue
      fi
      die "host port $p is already in use (set KONG_PROXY_PORT / KONG_ADMIN_PORT in .env)"
    fi
  fi
done

log "building and starting containers (first run builds the echo image)"
compose up -d --build

wait_healthy "$DB_CONTAINER" 240
wait_healthy "$KONG_CONTAINER" 240
wait_admin 60

log "applying Admin API configuration (idempotent)"
bash "$SCRIPT_DIR/configure.sh"

# ---------------------------------------------------- smoke ------------
# NOTE: the proxy has no /status route (only the Admin API does); the
# baseline /test-echo is the correct end-to-end readiness probe.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$PROXY_URL/test-echo")"
[ "$code" = "200" ] || die "proxy /test-echo returned $code after setup"

log "setup complete"
log "  proxy : $PROXY_URL"
log "  admin : $ADMIN_URL"
log "  next  : bash scripts/smoke-test.sh   (and docs/INSTALL.md)"
