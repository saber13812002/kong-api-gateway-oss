#!/usr/bin/env bash
# Kong OSS release — idempotent Admin API configuration.
#
# Creates the demo/test services, routes and plugin configs.
# ALL operations are upserts / find-or-create, so the script can be
# re-run any number of times (e.g. after a version upgrade).
#
# Upstream for every service is the echo backend, reached over the
# internal Docker network by its compose service name "echo"
# (always valid inside ${COMPOSE_PROJECT_NAME}-net, regardless of the
# project name).
#
# Layout (12 routes: 1 baseline + 11 test):
#   svc test-echo-svc     route /test-echo      (strip)  -> upstream /
#   svc t-req-header-svc  route /t-req-header   (strip)  -> upstream /
#   svc t-req-json-svc    route /t-req-json     (strip)  -> upstream /
#   svc t-resp-header-svc route /t-resp-header  (strip)  -> upstream /
#   svc t-resp-json-svc   route /fixed-ok       (keep)   -> upstream /fixed-ok
#   svc t-resp-edge-svc   routes /empty /not-json /echo-error (keep)
#   svc t-pre-svc         route /t-pre          (strip)  -> upstream /
#   svc t-post-svc        route /t-post         (keep)   -> upstream /t-post
#   svc secure-echo-svc   route /secure-echo    (strip)  -> upstream /
#   svc combined-svc      route /combined-echo  (keep)   -> upstream /combined-echo
#
# Plugins:
#   t-req-header-svc  request-transformer  replace header X-Client-Type
#   t-req-json-svc    request-transformer  replace JSON body
#   t-resp-header-svc response-transformer add header X-Gateway-Processed
#   t-resp-json-svc   oss-post             response JSON key rename
#   t-resp-edge-svc   oss-post             same (edge: empty/non-JSON/500)
#   t-pre-svc         oss-pre              auth (X-Api-Key) + correlation id
#                                           + request body rename
#   t-post-svc        oss-pre + oss-post   correlation id + response rename
#   secure-echo-svc   oss-pre              auth only (X-Api-Key presence)
#   combined-svc      oss-pre + oss-post   full request+response chain
source "$(dirname "$0")/_common.sh"

HOST="${ECHO_HOST:-echo}"      # compose service DNS name on the internal net
PORT="${ECHO_PORT:-9000}"
PY=python3

SID() {
  curl -fsS "$ADMIN_URL/services/$1" | $PY -c 'import sys,json;print(json.load(sys.stdin)["id"])'
}

# upsert_service <name>
upsert_service() {
  local id
  id=$(curl -fsS -X PUT "$ADMIN_URL/services/$1" \
    -H 'Content-Type: application/json' \
    -d "{\"host\":\"$HOST\",\"port\":$PORT,\"protocol\":\"http\",\"name\":\"$1\"}" \
    | $PY -c 'import sys,json;print(json.load(sys.stdin)["id"])')
  echo "[cfg] service $1 -> $id"
}

# upsert_route <name> <path> <service> <strip:true|false> [buffering:on]
#   buffering arg: any non-empty value enables response_buffering (JSON true).
upsert_route() {
  local name="$1" path="$2" svc="$3" strip="$4" buf="${5:-}"
  local s r payload
  s=$(SID "$svc")
  r=$(curl -fsS "$ADMIN_URL/routes?service_id=$s&size=100" | $PY -c '
import sys, json
p = sys.argv[1]
d = json.load(sys.stdin)
for r in d.get("data", []):
    if r.get("paths") == [p]:
        print(r["id"])
        break' "$path")
  # NOTE (Kong 3.9.4): `service_id` is a read-only relation on routes.
  # A TOP-LEVEL PUT /routes/{id} is a full update and NULLS the service
  # relation — always link/update via the nested endpoints
  # POST /services/{id}/routes  /  PUT /services/{id}/routes/{rid}.
  if [ -n "$buf" ]; then
    payload=$(printf '{"name":"%s","paths":["%s"],"strip_path":%s,"methods":["GET","POST"],"response_buffering":true}' \
      "$name" "$path" "$strip")
  else
    payload=$(printf '{"name":"%s","paths":["%s"],"strip_path":%s,"methods":["GET","POST"]}' \
      "$name" "$path" "$strip")
  fi
  if [ -n "$r" ]; then
    curl -fsS -X PUT "$ADMIN_URL/services/$s/routes/$r" -H 'Content-Type: application/json' -d "$payload" > /dev/null
    echo "[cfg] route $name ($path) PUT -> $r"
  else
    curl -fsS -X POST "$ADMIN_URL/services/$s/routes" -H 'Content-Type: application/json' -d "$payload" > /dev/null
    echo "[cfg] route $name ($path) POST -> created"
  fi
}

# upsert_plugin <service> <plugin-name> <config-json>
upsert_plugin() {
  local s p full
  s=$(SID "$1")
  # NOTE: the ?service_id= list filter does not work on /plugins in Kong 3.9.4;
  # use the nested endpoint instead.
  p=$(curl -fsS "$ADMIN_URL/services/$s/plugins?size=100" | $PY -c '
import sys, json
n = sys.argv[1]
d = json.load(sys.stdin)
for x in d.get("data", []):
    if x["name"] == n:
        print(x["id"])
        break' "$2")
  if [ -n "$p" ]; then
    # Kong 3.x: a TOP-LEVEL PUT /plugins/{id} is a full update and NULLS the
    # service relation (like routes). Always update via the nested endpoint.
    full=$(printf '{"name":"%s","config":%s}' "$2" "$3")
    curl -fsS -X PUT "$ADMIN_URL/services/$s/plugins/$p" \
      -H 'Content-Type: application/json' -d "$full" > /dev/null
    echo "[cfg] plugin $2 on $1 PUT -> $p"
  else
    # `service_id` is read-only on plugins (Kong >= 3.5): link via the
    # nested endpoint POST /services/{id}/plugins.
    full=$(printf '{"name":"%s","config":%s}' "$2" "$3")
    curl -fsS -X POST "$ADMIN_URL/services/$s/plugins" \
      -H 'Content-Type: application/json' -d "$full" > /dev/null
    echo "[cfg] plugin $2 on $1 POST -> created"
  fi
}

echo "[cfg] admin reachable:"
curl -fsS "$ADMIN_URL/" | $PY -c 'import sys,json;d=json.load(sys.stdin);print("  kong",d["version"])'

echo
echo "=== services ==="
upsert_service test-echo-svc
upsert_service t-req-header-svc
upsert_service t-req-json-svc
upsert_service t-resp-header-svc
upsert_service t-resp-json-svc
upsert_service t-resp-edge-svc
upsert_service t-pre-svc
upsert_service t-post-svc
upsert_service secure-echo-svc
upsert_service combined-svc

echo
echo "=== routes ==="
upsert_route test-echo-route      /test-echo      test-echo-svc     true
upsert_route t-req-header-route   /t-req-header   t-req-header-svc  true
upsert_route t-req-json-route     /t-req-json     t-req-json-svc    true
upsert_route t-resp-header-route  /t-resp-header  t-resp-header-svc true
upsert_route t-resp-json-route    /fixed-ok       t-resp-json-svc   false on
upsert_route t-resp-edge-empty    /empty          t-resp-edge-svc   false on
upsert_route t-resp-edge-notjson  /not-json       t-resp-edge-svc   false on
upsert_route t-resp-edge-error    /echo-error     t-resp-edge-svc   false on
upsert_route t-pre-route          /t-pre          t-pre-svc         true
upsert_route t-post-route         /t-post         t-post-svc        false on
upsert_route secure-echo-route    /secure-echo    secure-echo-svc   true
upsert_route combined-route       /combined-echo  combined-svc      false on

echo
echo "=== plugins ==="
# OSS request header transform (request-transformer, replace)
upsert_plugin t-req-header-svc request-transformer \
  '{"replace":{"headers":["X-Client-Type: modern"]}}'
# OSS request JSON body transform (request-transformer, remove + add).
# NOTE (Kong 3.9.4 semantics):
#  * `replace.body` only overwrites keys that ALREADY exist in the parsed
#    JSON body, while `add.body` only sets keys that are ABSENT. Since the
#    original keys are removed first, the new keys must go in `add.body`.
#  * pair strings are parsed as "^([^:]+):*(.-)$" — the value is the raw
#    remainder after the colon, so NO space after the colon ("key:value"),
#    otherwise the rendered value carries a leading space.
upsert_plugin t-req-json-svc request-transformer \
  '{"remove":{"body":["customer_id","anything"]},"add":{"body":["customerId:123","name:Ali"]}}'
# OSS response header add (response-transformer)
upsert_plugin t-resp-header-svc response-transformer \
  '{"add":{"headers":["X-Gateway-Processed: kong"]}}'
# oss-post: response JSON body transform (deterministic /fixed-ok)
upsert_plugin t-resp-json-svc oss-post \
  '{"transform_body":true,"key_rename":{"status":"success"},"resp_header_name":"X-Oss-Post","resp_header_value":"processed"}'
# oss-post on edge routes: empty / non-JSON / 500 responses (robustness)
upsert_plugin t-resp-edge-svc oss-post \
  '{"transform_body":true,"key_rename":{"status":"success"},"resp_header_name":"X-Oss-Post","resp_header_value":"processed"}'
# oss-pre: auth (required X-Api-Key) + correlation id + request body rename
upsert_plugin t-pre-svc oss-pre \
  '{"required_headers":["X-Api-Key"],"correlation_id_header":"X-Correlation-Id","body_rename":{"customer_id":"customerId"}}'
# oss-pre + oss-post on /t-post: correlation id + response body rename
upsert_plugin t-post-svc oss-pre \
  '{"correlation_id_header":"X-Correlation-Id"}'
upsert_plugin t-post-svc oss-post \
  '{"transform_body":true,"key_rename":{"backend":"gateway"},"resp_header_name":"X-Oss-Post","resp_header_value":"processed","echo_request_header":"X-Correlation-Id"}'
# oss-pre: pure auth route (X-Api-Key presence check)
upsert_plugin secure-echo-svc oss-pre \
  '{"required_headers":["X-Api-Key"]}'
# full chain: pre (auth + correlation + request rename) + post (resp rename)
upsert_plugin combined-svc oss-pre \
  '{"required_headers":["X-Api-Key"],"correlation_id_header":"X-Correlation-Id","body_rename":{"customer_id":"customerId"}}'
upsert_plugin combined-svc oss-post \
  '{"transform_body":true,"key_rename":{"status":"success"},"resp_header_name":"X-Oss-Post","resp_header_value":"processed","echo_request_header":"X-Correlation-Id"}'

echo
echo "=== summary: all routes now ==="
curl -fsS "$ADMIN_URL/routes?size=100" | $PY -c '
import sys, json
d = json.load(sys.stdin)
for r in sorted(d["data"], key=lambda x: (x["name"])):
    name, paths, strip, buf = r["name"], str(r["paths"]), str(r.get("strip_path")), str(r.get("response_buffering", "inherit"))
    print("  %s %s strip=%s buffering=%s" % (name.ljust(22), paths.ljust(18), strip.ljust(5), buf))
print("total routes: %d (expect 1 baseline + 11 test)" % len(d["data"]))
'
echo "[cfg] done"
