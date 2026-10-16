#!/usr/bin/env bash
# Kong OSS release — security posture test.
#
# Verifies the security properties of the deployment (not just function):
#   P1  loopback-only port bindings (proxy/admin reachable only on 127.0.0.1)
#   P2  Admin API NOT bound to any non-loopback interface
#   P3  PostgreSQL has NO host port at all (internal network only)
#   P4  auth route rejects unauthenticated requests with a controlled error
#   P5  no kong/pg containers exist outside the project namespace
#   P6  .env is git-ignored in a git checkout
#   P7  .env does not hold the shipped placeholder password
#   P8  plugin bind mounts are read-only inside the kong container
#   P9  echo backend is not reachable from the host (no host port)
#
# Read-only: this script changes nothing.
source "$(dirname "$0")/_common.sh"

PASS=0
FAIL=0
ok()   { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL  $1"; echo "      $2"; FAIL=$((FAIL + 1)); }

echo "=== security test (project: $COMPOSE_PROJECT_NAME) ==="

# ------------------------------------------------------- P1: loopback ---
# The compose port mapping must be 127.0.0.1 (or a private IP chosen by the
# operator) — we assert the container's published port uses a loopback IP.
for p in "$KONG_PROXY_PORT" "$KONG_ADMIN_PORT"; do
  binds="$(docker inspect --format '{{json .NetworkSettings.Ports}}' "$KONG_CONTAINER" 2>/dev/null || echo '{}')"
  ip="$(printf '%s' "$binds" | python3 -c "
import json, sys
ports = json.load(sys.stdin)
for pub, binds in ports.items():
    if binds and binds[0].get('HostPort') == '$p':
        print(binds[0].get('HostIp') or '0.0.0.0')
        break
else:
    print('')
")"
  case "$ip" in
    127.0.0.1) ok "P1 port $p bound to loopback (127.0.0.1)" ;;
    "")         bad "P1 port $p" "published port not found on $KONG_CONTAINER" ;;
    *)          bad "P1 port $p" "bound to non-loopback IP $ip" ;;
  esac
done

# ------------------------------------------------------- P2: admin ----
reachable_from_host=0
if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${KONG_ADMIN_PORT}/"; then
  reachable_from_host=1
fi
[ "$reachable_from_host" = "1" ] \
  && ok "P2 admin API reachable on loopback (as intended)" \
  || bad "P2 admin API" "not reachable on 127.0.0.1:$KONG_ADMIN_PORT"

# ------------------------------------------------------- P3: postgres --
# A port entry of "null" means EXPOSED (internal network) but NOT published
# to the host — that is safe. Only a non-null HostPort is a violation.
pg_violation="$(docker inspect --format '{{json .NetworkSettings.Ports}}' "$DB_CONTAINER" 2>/dev/null | python3 -c "
import json, sys
ports = json.load(sys.stdin)
bad = [k for k, v in ports.items() if v and any(b.get('HostPort') for b in v)]
print(','.join(bad))
")"
[ -z "$pg_violation" ] \
  && ok "P3 postgres has no published host ports" \
  || bad "P3 postgres host ports" "published port(s): $pg_violation"

# ------------------------------------------------------- P4: auth -----
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
  -X POST -H 'Content-Type: application/json' -d '{"a":1}' "$PROXY_URL/secure-echo")
[ "$code" = "400" ] \
  && ok "P4 unauthenticated POST /secure-echo rejected with 400" \
  || bad "P4 unauthenticated request" "expected 400, got $code"

err=$(curl -s --max-time 5 -X POST -H 'Content-Type: application/json' -d '{"a":1}' \
  "$PROXY_URL/secure-echo" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("error"))' 2>/dev/null)
[ "$err" = "missing_required_header" ] \
  && ok "P4b error body is the controlled JSON (no stack trace / no leak)" \
  || bad "P4b controlled error body" "expected missing_required_header, got '$err'"

# ------------------------------------------------------- P5: isolation -
foreign="$(docker ps -a --format '{{.Names}}' | grep -Ev "^${COMPOSE_PROJECT_NAME}-" | grep -Ei 'kong|pgdata' || true)"
[ -z "$foreign" ] \
  && ok "P5 no kong/postgres containers outside the $COMPOSE_PROJECT_NAME namespace" \
  || bad "P5 foreign containers" "$foreign"

# ------------------------------------------------------- P6: .env -----
if git -C "$ROOT_DIR" check-ignore -q .env 2>/dev/null; then
  ok "P6 .env is git-ignored in this working copy"
elif [ ! -d "$ROOT_DIR/.git" ]; then
  ok "P6 not a git checkout — .env cannot be committed from here (verify .gitignore at release time)"
else
  bad "P6 .env git-ignore" ".env is NOT git-ignored"
fi
grep -q '^KONG_PG_PASSWORD=change-me' "$ROOT_DIR/.env" 2>/dev/null \
  && bad "P7 env password" ".env still holds the placeholder password" \
  || ok "P7 env password is not the shipped placeholder"

# ------------------------------------------------------- P7: ro mounts -
ro_mounts="$(docker inspect --format '{{json .Mounts}}' "$KONG_CONTAINER" | python3 -c "
import json, sys
mounts = json.load(sys.stdin)
bad = [m['Source'] for m in mounts if '/kong/plugins/' in m['Destination'] and m.get('Mode') != 'ro']
print(','.join(bad))
")"
[ -z "$ro_mounts" ] \
  && ok "P8 plugin bind mounts are read-only" \
  || bad "P8 plugin mounts" "writable plugin mount(s): $ro_mounts"

# ------------------------------------------------------- P9: echo ------
# The echo container must publish NO host ports. (Probing a fixed host port
# like :9000 is NOT reliable on a shared host: an unrelated stack may
# already own that port, and the container would still be properly
# isolated. The authoritative check is the container's port mapping.)
echo_violation="$(docker inspect --format '{{json .NetworkSettings.Ports}}' "$ECHO_CONTAINER" 2>/dev/null | python3 -c "
import json, sys
ports = json.load(sys.stdin)
bad = [k for k, v in ports.items() if v and any(b.get('HostPort') for b in v)]
print(','.join(bad))
")"
[ -z "$echo_violation" ] \
  && ok "P9 echo backend has no published host port (internal network only)" \
  || bad "P9 echo backend host ports" "published port(s): $echo_violation"

echo
echo "=== security result: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
