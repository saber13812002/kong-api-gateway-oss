#!/usr/bin/env bash
# STEP 4 — deploy custom plugins + deterministic echo endpoints.
#
# Safe, idempotent, surgical:
#   * rebuilds kong-gw-trial-echo (new deterministic endpoints)
#   * recreates ONLY kong-gw-trial-kong (new read-only plugin mounts +
#     KONG_PLUGINS). Postgres, migrate, bench and all pre-existing
#     containers are untouched.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[deploy] pre-state:"
docker ps --format 'table {{.Names}}\t{{.Status}}' | head -5
docker ps --format '{{.Names}}' | wc -l

echo "[deploy] building echo (v1.1, deterministic endpoints)"
docker compose build kong-gw-echo

echo "[deploy] recreating echo + kong (only these two containers)"
docker compose up -d kong-gw-echo kong-gw

echo "[deploy] waiting for echo healthy"
for i in $(seq 1 30); do
  code=$(docker exec kong-gw-trial-echo wget -q -O- http://127.0.0.1:9000/health 2>/dev/null | grep -c '"status":"ok"' || true)
  [ "$code" = "1" ] && break
  sleep 1
done
echo "[deploy] echo health:"
docker exec kong-gw-trial-echo wget -q -O- http://127.0.0.1:9000/health
echo
echo "[deploy] deterministic endpoints (direct to echo container, no proxy):"
echo -n "  /fixed-ok  -> "; docker exec kong-gw-trial-echo wget -q -O- http://127.0.0.1:9000/fixed-ok; echo
echo -n "  /not-json  -> "; docker exec kong-gw-trial-echo wget -q -O- http://127.0.0.1:9000/not-json; echo
echo -n "  /empty     -> "
bodylen=$(docker exec kong-gw-trial-echo wget -q -O- http://127.0.0.1:9000/empty | wc -c)
echo "len=$bodylen (expect 0)"
echo -n "  /echo-error-> "; docker exec kong-gw-trial-echo wget -q -O- http://127.0.0.1:9000/echo-error 2>&1 | head -1; echo
echo -n "  /combined-echo (POST, transformed body) -> "
docker exec kong-gw-trial-echo wget -q -O- --post-data '{"customerId":123,"name":"Ali"}' --header='Content-Type: application/json' --header='X-Correlation-Id: deploy-check' http://127.0.0.1:9000/combined-echo; echo
echo -n "  /combined-echo (POST, UNTRANSFORMED body, expect 400) -> "
docker exec kong-gw-trial-echo wget -q -O- --post-data '{"customer_id":123,"name":"Ali"}' --header='Content-Type: application/json' http://127.0.0.1:9000/combined-echo 2>&1 | head -1; echo

echo
echo "[deploy] waiting for kong healthy (admin up, plugins loaded)"
for i in $(seq 1 60); do
  state=$(docker inspect -f '{{.State.Health.Status}}' kong-gw-trial-kong 2>/dev/null || echo starting)
  if [ "$state" = "healthy" ]; then break; fi
  sleep 2
done
docker inspect -f 'kong health: {{.State.Health.Status}}' kong-gw-trial-kong

echo
echo "[deploy] custom plugin files present in container:"
docker exec kong-gw-trial-kong ls -la \
  /usr/local/share/lua/5.1/kong/plugins/step4-pre \
  /usr/local/share/lua/5.1/kong/plugins/step4-post

echo
echo "[deploy] Kong config loaded:"
docker exec kong-gw-trial-kong bash -lc \
  'kong conf list | grep -E "plugins|proxy_listen|admin_listen" || true'

echo
echo "[deploy] post-state:"
docker ps --format 'table {{.Names}}\t{{.Status}}' | head -8
echo "containers running: $(docker ps -q | wc -l)  (must be 39, no pre-existing touched)"
echo "[deploy] done"
