#!/usr/bin/env bash
# Kong OSS release — smoke test (fast end-to-end sanity check).
#
# Talks only to the loopback proxy + admin API. Exits 0 only if every
# check passes.
source "$(dirname "$0")/_common.sh"

PASS=0
FAIL=0

check() { # check <id> <description> <expected> <actual>
  local id="$1" desc="$2" expected="$3" actual="$4"
  if [ "$expected" = "$actual" ]; then
    echo "PASS  $id  $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $id  $desc"
    echo "      expected: $expected"
    echo "      actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
jsonget() { # jsonget <url> <method> [data] <python-expr-on-d> [extra curl args...]
  local url="$1" method="$2" data="${3:-}" expr="$4"
  shift 4
  local extra=("$@")
  local tmp; tmp="$(mktemp)"
  if [ -n "$data" ]; then
    curl -s --max-time 15 -X "$method" -H 'Content-Type: application/json' \
      -d "$data" "${extra[@]}" "$url" -o "$tmp"
  else
    curl -s --max-time 15 -X "$method" "${extra[@]}" "$url" -o "$tmp"
  fi
  python3 -c "
import json
try:
    d = json.load(open('$tmp'))
except Exception:
    print('UNPARSEABLE')
    raise SystemExit(0)
print($expr)
" 2>/dev/null || echo PARSE_ERROR
  rm -f "$tmp"
}

echo "=== smoke test (proxy: $PROXY_URL, admin: $ADMIN_URL) ==="

# 1. admin /status (proxy has no /status route; /test-echo is the baseline)
check "S1" "admin /status reachable" "200" "$(code "$ADMIN_URL/status")"

# 2. admin API
check "S2" "admin API reachable" "200" "$(code "$ADMIN_URL/")"

# 3. container health
check "S3" "db container healthy" "healthy" "$(container_health "$DB_CONTAINER")"
check "S4" "kong container healthy" "healthy" "$(container_health "$KONG_CONTAINER")"
check "S5" "echo container running" "running" "$(container_state "$ECHO_CONTAINER")"

# 4. baseline echo through kong
check "S6" "GET /test-echo -> 200" "200" "$(code "$PROXY_URL/test-echo")"
check "S7" "GET /test-echo reports backend" "$ECHO_BACKEND_NAME" \
  "$(jsonget "$PROXY_URL/test-echo" GET '' 'd.get("backend")')"

# 5. auth: missing header -> 400 controlled JSON
check "S8" "POST /secure-echo without X-Api-Key -> 400" "400" \
  "$(code -X POST -H 'Content-Type: application/json' -d '{"a":1}' "$PROXY_URL/secure-echo")"
check "S9" "400 body is controlled JSON (missing_required_header)" "missing_required_header" \
  "$(jsonget "$PROXY_URL/secure-echo" POST '{"a":1}' 'd.get("error")')"

# 6. auth: valid header -> 200
check "S10" "POST /secure-echo with X-Api-Key -> 200" "200" \
  "$(code -X POST -H 'Content-Type: application/json' -H 'X-Api-Key: smoke' -d '{"a":1}' "$PROXY_URL/secure-echo")"

# 7. oss-pre body rename on /t-pre (requires X-Api-Key per plugin config)
check "S11" "POST /t-pre renames customer_id -> customerId" "1234" \
  "$(jsonget "$PROXY_URL/t-pre" POST '{"customer_id":1234}' 'd.get("body", {}).get("customerId")' \
    -H 'X-Api-Key: smoke')"

# 8. oss-post response transform on /fixed-ok
check "S12" "GET /fixed-ok -> success (renamed from status)" "ok" \
  "$(jsonget "$PROXY_URL/fixed-ok" GET '' 'd.get("success")')"
HDR=$(curl -s -D - -o /dev/null --max-time 10 "$PROXY_URL/fixed-ok" | tr -d '\r' | awk 'BEGIN{IGNORECASE=1} /^x-oss-post:/ {print $2}')
check "S13" "GET /fixed-ok adds X-Oss-Post: processed" "processed" "$HDR"

# 9. OSS response-transformer header
HDR2=$(curl -s -D - -o /dev/null --max-time 10 -H 'X-Client-Type: legacy' "$PROXY_URL/t-resp-header" | tr -d '\r' | awk 'BEGIN{IGNORECASE=1} /^x-gateway-processed:/ {print $2}')
check "S14" "GET /t-resp-header adds X-Gateway-Processed: kong" "kong" "$HDR2"

echo
echo "=== smoke result: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
