#!/usr/bin/env bash
# STEP 4 — idempotent Admin API configuration (idempotent, re-runnable).
#
# Creates 8 isolated test services + 10 test routes + plugin configs.
# ALL operations are upserts / find-or-create. The baseline /test-echo
# route is NOT touched.
#
# Layout (upstream = kong-gw-trial-echo:9000):
#   svc t-req-header-svc   route /t-req-header  (strip)  -> upstream /
#   svc t-req-json-svc     route /t-req-json    (strip)  -> upstream /
#   svc t-resp-header-svc  route /t-resp-header (strip)  -> upstream /
#   svc t-resp-json-svc    route /fixed-ok      (keep)   -> upstream /fixed-ok
#   svc t-resp-edge-svc    routes /empty /not-json /echo-error (keep)
#   svc t-custom-pre-svc   route /t-custom-pre  (strip)  -> upstream /
#   svc t-custom-post-svc  route /t-custom-post (strip)  -> upstream /
#   svc t-combined-svc     route /combined-echo (keep)   -> upstream /combined-echo
set -euo pipefail

ADMIN="http://127.0.0.1:18001"
HOST="kong-gw-trial-echo"
PY=python3

SID() {
  curl -fsS "$ADMIN/services/$1" | $PY -c 'import sys,json;print(json.load(sys.stdin)["id"])'
}

# upsert_service <name>
upsert_service() {
  local id
  id=$(curl -fsS -X PUT "$ADMIN/services/$1" \
    -H 'Content-Type: application/json' \
    -d "{\"host\":\"$HOST\",\"port\":9000,\"protocol\":\"http\",\"name\":\"$1\"}" \
    | $PY -c 'import sys,json;print(json.load(sys.stdin)["id"])')
  echo "[cfg] service $1 -> $id"
}

# upsert_route <name> <path> <service> <strip:true|false> [buffering:on]
upsert_route() {
  local name="$1" path="$2" svc="$3" strip="$4" buf="${5:-}"
  local s r payload
  s=$(SID "$svc")
  r=$(curl -fsS "$ADMIN/routes?service_id=$s&size=100" | $PY -c '
import sys, json
p = sys.argv[1]
d = json.load(sys.stdin)
for r in d.get("data", []):
    if r.get("paths") == [p]:
        print(r["id"])
        break' "$path")
  if [ -n "$buf" ]; then
    payload=$(printf '{"name":"%s","paths":["%s"],"strip_path":%s,"methods":["GET","POST"],"response_buffering":"%s","service_id":"%s"}' \
      "$name" "$path" "$strip" "$buf" "$s")
  else
    payload=$(printf '{"name":"%s","paths":["%s"],"strip_path":%s,"methods":["GET","POST"],"service_id":"%s"}' \
      "$name" "$path" "$strip" "$s")
  fi
  if [ -n "$r" ]; then
    curl -fsS -X PUT "$ADMIN/routes/$r" -H 'Content-Type: application/json' -d "$payload" > /dev/null
    echo "[cfg] route $name ($path) PUT -> $r"
  else
    curl -fsS -X POST "$ADMIN/routes" -H 'Content-Type: application/json' -d "$payload" > /dev/null
    echo "[cfg] route $name ($path) POST -> created"
  fi
}

# upsert_plugin <service> <plugin-name> <config-json>
upsert_plugin() {
  local s p full
  s=$(SID "$1")
  p=$(curl -fsS "$ADMIN/plugins?service_id=$s&size=100" | $PY -c '
import sys, json
n = sys.argv[1]
d = json.load(sys.stdin)
for x in d.get("data", []):
    if x["name"] == n:
        print(x["id"])
        break' "$2")
  if [ -n "$p" ]; then
    curl -fsS -X PUT "$ADMIN/plugins/$p" \
      -H 'Content-Type: application/json' -d "$3" > /dev/null
    echo "[cfg] plugin $2 on $1 PUT -> $p"
  else
    full=$(printf '{"name":"%s","service_id":"%s","config":%s}' "$2" "$s" "$3")
    curl -fsS -X POST "$ADMIN/plugins" \
      -H 'Content-Type: application/json' -d "$full" > /dev/null
    echo "[cfg] plugin $2 on $1 POST -> created"
  fi
}

echo "[cfg] admin reachable:"
curl -fsS "$ADMIN/" | $PY -c 'import sys,json;d=json.load(sys.stdin);print("  kong",d["version"])'

echo
echo "=== baseline /test-echo BEFORE (must remain unchanged) ==="
curl -fsS "$ADMIN/routes?size=100" | $PY -c '
import sys, json
d = json.load(sys.stdin)
for r in d.get("data", []):
    if r.get("paths") == ["/test-echo"]:
        print("  baseline route id:", r["id"], "strip:", r.get("strip_path"), "methods:", r.get("methods"))
'

echo
echo "=== services ==="
upsert_service t-req-header-svc
upsert_service t-req-json-svc
upsert_service t-resp-header-svc
upsert_service t-resp-json-svc
upsert_service t-resp-edge-svc
upsert_service t-custom-pre-svc
upsert_service t-custom-post-svc
upsert_service t-combined-svc

echo
echo "=== routes ==="
upsert_route t-req-header-route  /t-req-header  t-req-header-svc   true
upsert_route t-req-json-route    /t-req-json    t-req-json-svc     true
upsert_route t-resp-header-route /t-resp-header t-resp-header-svc  true
upsert_route t-resp-json-route   /fixed-ok      t-resp-json-svc    false on
upsert_route t-resp-edge-empty   /empty         t-resp-edge-svc    false on
upsert_route t-resp-edge-notjson /not-json      t-resp-edge-svc    false on
upsert_route t-resp-edge-error   /echo-error    t-resp-edge-svc    false on
upsert_route t-custom-pre-route  /t-custom-pre  t-custom-pre-svc   true
upsert_route t-custom-post-route /t-custom-post t-custom-post-svc  false on
upsert_route t-combined-route    /combined-echo t-combined-svc     false on

echo
echo "=== plugins ==="
# B: request header transform (OSS request-transformer, replace)
upsert_plugin t-req-header-svc request-transformer \
  '{"replace":{"headers":{"X-Client-Type":"modern"}}}'
# C: request JSON body transform (OSS request-transformer, replace body)
upsert_plugin t-req-json-svc request-transformer \
  '{"replace":{"body":{"customerId":123,"name":"Ali"}}}'
# D: response header add (OSS response-transformer)
upsert_plugin t-resp-header-svc response-transformer \
  '{"add":{"headers":{"X-Gateway-Processed":"kong"}}}'
# E: response JSON body transform (custom step4-post, deterministic /fixed-ok)
upsert_plugin t-resp-json-svc step4-post \
  '{"transform_body":true,"key_rename":{"status":"success"},"resp_header_name":"X-Step4-Post","resp_header_value":"processed"}'
# E-edge: empty / non-JSON / error responses (same plugin, robustness proof)
upsert_plugin t-resp-edge-svc step4-post \
  '{"transform_body":true,"key_rename":{"status":"success"},"resp_header_name":"X-Step4-Post","resp_header_value":"processed"}'
# F: custom pre-processing (validate + correlation id + body rename)
upsert_plugin t-custom-pre-svc step4-pre \
  '{"required_headers":["X-Api-Key"],"correlation_id_header":"X-Correlation-Id","body_rename":{"customer_id":"customerId"}}'
# G: custom post-processing (response header + correlation echo + body rename)
upsert_plugin t-custom-post-svc step4-pre \
  '{"correlation_id_header":"X-Correlation-Id"}'
upsert_plugin t-custom-post-svc step4-post \
  '{"transform_body":true,"key_rename":{"backend":"gateway"},"resp_header_name":"X-Step4-Post","resp_header_value":"processed","echo_request_header":"X-Correlation-Id"}'
# H: combined pre + post
upsert_plugin t-combined-svc step4-pre \
  '{"required_headers":["X-Api-Key"],"correlation_id_header":"X-Correlation-Id","body_rename":{"customer_id":"customerId"}}'
upsert_plugin t-combined-svc step4-post \
  '{"transform_body":true,"key_rename":{"status":"success"},"resp_header_name":"X-Step4-Post","resp_header_value":"processed","echo_request_header":"X-Correlation-Id"}'

echo
echo "=== summary: all routes now ==="
curl -fsS "$ADMIN/routes?size=100" | $PY -c '
import sys, json
d = json.load(sys.stdin)
for r in sorted(d["data"], key=lambda x: (x["name"])):
    print(f"  {r[\"name\"]:22} {str(r[\"paths\"]):18} strip={str(r.get(\"strip_path\")):5} buffering={r.get(\"response_buffering\", \"inherit\")}")
print(f"total routes: {d[\"total\"]} (1 baseline + 10 test)")
'
echo "[cfg] done"
