#!/usr/bin/env bash
# Shared helpers for the Kong OSS release scripts.
# Sourced by the other scripts:  source "$(dirname "$0")/_common.sh"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------- env ---
# Load .env if present (does not override variables already exported).
if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ROOT_DIR/.env"
  set +a
fi

: "${COMPOSE_PROJECT_NAME:=kong-gw-oss}"
: "${KONG_PROXY_PORT:=18080}"
: "${KONG_ADMIN_PORT:=18001}"
: "${ECHO_BACKEND_NAME:=oss-echo}"
export COMPOSE_PROJECT_NAME KONG_PROXY_PORT KONG_ADMIN_PORT ECHO_BACKEND_NAME

COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
PROXY_URL="http://127.0.0.1:${KONG_PROXY_PORT}"
ADMIN_URL="http://127.0.0.1:${KONG_ADMIN_PORT}"
KONG_CONTAINER="${COMPOSE_PROJECT_NAME}-kong"
DB_CONTAINER="${COMPOSE_PROJECT_NAME}-db"
ECHO_CONTAINER="${COMPOSE_PROJECT_NAME}-echo"
NETWORK_NAME="${COMPOSE_PROJECT_NAME}-net"

# ---------------------------------------------------------------- utils ---
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found in PATH"
}

compose() {
  docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" "$@"
}

container_state()  { docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo missing; }
container_health() { docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$1" 2>/dev/null || echo unknown; }

# wait_healthy <container> [timeout-s]
wait_healthy() {
  local c="$1" timeout="${2:-180}" i=0
  while [ "$i" -lt "$timeout" ]; do
    local h; h="$(container_health "$c")"
    if [ "$h" = "healthy" ]; then
      log "$c is healthy"
      return 0
    fi
    case "$(container_state "$c")" in
      exited|dead)
        log "$c stopped with state '$(container_state "$c")'; last log lines:"
        docker logs --tail 25 "$c" 2>&1 || true
        return 1
        ;;
    esac
    sleep 3
    i=$((i + 3))
  done
  die "timed out after ${timeout}s waiting for $c to become healthy"
}

# wait_admin [timeout-s] — poll the Admin API until it answers 200
wait_admin() {
  local timeout="${1:-120}" i=0 code
  while [ "$i" -lt "$timeout" ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$ADMIN_URL/" || true)"
    if [ "$code" = "200" ]; then
      log "admin API up ($ADMIN_URL)"
      return 0
    fi
    sleep 3
    i=$((i + 3))
  done
  die "admin API did not become reachable within ${timeout}s"
}

# wait_kong_healthy [timeout-s] — used by restart/benchmark scripts
wait_kong_healthy() { wait_healthy "$KONG_CONTAINER" "${1:-180}"; }
