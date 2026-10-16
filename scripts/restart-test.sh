#!/usr/bin/env bash
# Kong OSS release — restart / stability test.
#
# 1. records a "before" fingerprint (kong pid, migrations state, a sample
#    request through each configured route)
# 2. restarts the kong container (docker compose restart kong) — the
#    database volume is untouched
# 3. waits for the kong healthcheck to pass again
# 4. records an "after" fingerprint and compares
#
# Only the kong container is restarted; db/echo keep running.
source "$(dirname "$0")/_common.sh"

PASS=0
FAIL=0
check() {
  local id="$1" desc="$2" expected="$3" actual="$4"
  if [ "$expected" = "$actual" ]; then
    echo "PASS  $id  $desc"; PASS=$((PASS + 1))
  else
    echo "FAIL  $id  $desc"; echo "      expected: $expected"; echo "      actual:   $actual"; FAIL=$((FAIL + 1))
  fi
}

fingerprint() { # writes one line per route: "<path> <http_code>"
  local p
  for p in /test-echo /t-req-header /t-req-json /t-resp-header /fixed-ok /empty /not-json /echo-error /t-pre /t-post /combined-echo; do
    local c
    c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
      -H 'Content-Type: application/json' -H 'X-Api-Key: restart-test' \
      -d '{"customer_id":1}' "$PROXY_URL$p" || echo 000)"
    # /t-resp-header and /fixed-ok etc. are POST-capable (methods GET,POST)
    echo "$p $c"
  done
  # plus the deterministic auth failure case
  echo "/secure-echo(nokey) $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST -H 'Content-Type: application/json' -d '{"a":1}' "$PROXY_URL/secure-echo")"
}

BEFORE_FILE="$(mktemp)"
AFTER_FILE="$(mktemp)"
trap 'rm -f "$BEFORE_FILE" "$AFTER_FILE"' EXIT

echo "=== restart test (kong container only; db + echo stay up) ==="

[ "$(container_state "$KONG_CONTAINER")" = "running" ] || die "kong container not running"

PID_BEFORE="$(docker inspect --format '{{.State.Pid}}' "$KONG_CONTAINER")"
fingerprint > "$BEFORE_FILE"

log "restarting $KONG_CONTAINER ..."
compose restart kong

wait_kong_healthy 180
wait_admin 60

# Warm-up: the first proxied requests after a Kong restart can be slow or
# fail while workers re-warm the node cache / upstream DNS. Probe the
# baseline route until it answers 200 (max ~30s) before taking the
# "after" fingerprint.
for i in $(seq 1 15); do
  wc="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST \
    -H 'Content-Type: application/json' -H 'X-Api-Key: restart-test' \
    -d '{"customer_id":1}' "$PROXY_URL/test-echo" || echo 000)"
  [ "$wc" = "200" ] && break
  sleep 2
done
log "proxy warm-up done (last probe: $wc)"

PID_AFTER="$(docker inspect --format '{{.State.Pid}}' "$KONG_CONTAINER")"
fingerprint > "$AFTER_FILE"

# ------------------------------------------------- assertions ----------
if [ -n "$PID_BEFORE" ] && [ "$PID_BEFORE" != "0" ] && [ "$PID_BEFORE" != "$PID_AFTER" ]; then
  check "R1" "kong process actually restarted (pid changed)" "changed" "changed"
else
  check "R1" "kong process actually restarted (pid changed)" "changed" "same(pid=$PID_BEFORE)"
fi

check "R2" "db container still running (not restarted by the test)" "running" "$(container_state "$DB_CONTAINER")"
check "R3" "echo container still running" "running" "$(container_state "$ECHO_CONTAINER")"
check "R4" "kong healthy after restart" "healthy" "$(container_health "$KONG_CONTAINER")"

# per-route fingerprint must be identical
if diff -u "$BEFORE_FILE" "$AFTER_FILE" > /tmp/restart-diff.$$ 2>&1; then
  check "R5" "all 12 routes behave identically after restart" "identical" "identical"
else
  check "R5" "all 12 routes behave identically after restart" "identical" "differs"
  echo "      $(cat /tmp/restart-diff.$$ | head -n 20)"
  rm -f /tmp/restart-diff.$$
fi
rm -f /tmp/restart-diff.$$ 2>/dev/null || true

# config survived: count services/routes
# NOTE: Kong 3.x Admin API list responses have no "total" key; count data[]
# (fetch a page large enough to see all entities).
N_SVC="$(curl -fsS "$ADMIN_URL/services?size=100" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["data"]))' 2>/dev/null || echo 0)"
N_RT="$(curl -fsS "$ADMIN_URL/routes?size=100" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["data"]))' 2>/dev/null || echo 0)"
[ "$N_SVC" -ge 10 ] && [ "$N_RT" -ge 12 ] \
  && check "R6" "configuration survived restart ($N_SVC services, $N_RT routes)" "survived" "survived" \
  || check "R6" "configuration survived restart" "survived" "missing(svc=$N_SVC,route=$N_RT)"

echo
echo "=== restart result: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
