#!/usr/bin/env bash
# ai-gateway.sh — idempotently configure the LiteLLM-like AI gateway on this Kong.
#
# What it creates (all idempotent upserts by name, nested endpoints only):
#   consumer  ai-consumer            (key-auth credential stored on-server, 600)
#   service   ai-gw                  -> host AI backend (OpenAI-compatible)
#   route     ai-gw-v1               /ai (strip_path) -> backend /v1/*
#   route plugins (scoped to the route, never global):
#     key-auth       api-key / X-Api-Key header, hide_credentials
#     rate-limiting  policy=local (single-node semantics — documented OSS limit)
#     oss-pre        adds X-Correlation-Id when missing, echoes it to the client
#     post-function  METADATA-ONLY access log (method, path, status, duration,
#                    correlation id, consumer). Never logs request/response
#                    bodies or headers -> prompt content cannot reach the log.
#
# Provider keys (vLLM/LiteLLM upstreams) are NOT Kong config: the backends on
# this host are unauthenticated; when a backend needs a key, add it at the
# AI tier (e.g. a request-transformer header set here is NOT recommended —
# keep provider keys out of the Admin API entirely, see docs/SECURITY.md).
#
# Env: AI_HOST (default 127.0.0.1 — set to the OpenAI-compatible backend),
#      AI_PORT (default 8000),
#      ADMIN_URL (default http://127.0.0.1:18001),
#      CREDS_FILE (default <repo>/_export/ai-gw-creds)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ADMIN_URL="${ADMIN_URL:-http://127.0.0.1:18001}"
AI_HOST="${AI_HOST:-127.0.0.1}"
AI_PORT="${AI_PORT:-8000}"
CREDS_FILE="${CREDS_FILE:-$ROOT_DIR/_export/ai-gw-creds}"

log() { printf '[ai-gw] %s\n' "$*"; }
die() { printf '[ai-gw] FATAL: %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null || die "python3 not found"
curl -fsS "$ADMIN_URL/status" >/dev/null 2>&1 || die "Admin API not reachable at $ADMIN_URL"

python3 - "$ADMIN_URL" "$AI_HOST" "$AI_PORT" "$CREDS_FILE" <<'PY'
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

admin, ai_host, ai_port, creds_file = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        admin + path, data=data, method=method,
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw.decode()[:300]}


def by_name(kind, name):
    # NOTE: Kong 3.9.4 list filters (?name=) are NOT supported on some
    # collections (plugins) — they return 400. Fetch the full page and
    # match client-side instead.
    code, body = call("GET", "/%s?size=500" % kind)
    if code == 200 and isinstance(body, dict):
        for x in body.get("data", []):
            if x.get("name") == name or x.get("username") == name:
                return x
    return None


def upsert(kind, payload):
    cur = by_name(kind, payload.get("name") or payload.get("username"))
    if cur:
        code, body = call("PUT", "/%s/%s" % (kind, cur["id"]), payload)
        if code != 200:
            print("  PUT %s error: %s" % (kind, body))
        return ("updated" if code == 200 else "ERROR"), code
    code, body = call("POST", "/" + kind, payload)
    if code not in (200, 201):
        print("  POST %s error: %s" % (kind, body))
    return ("created" if code in (200, 201) else "ERROR"), code


def find_route(sid, name):
    """Route id by (name, service) — Kong 3.9.4 list filters (?name=) are
    unreliable/unsupported on several collections, so match client-side."""
    code, body = call("GET", "/routes?size=500")
    if code == 200 and isinstance(body, dict):
        for x in body.get("data", []):
            if x.get("name") == name:
                s = x.get("service")
                if isinstance(s, dict) and s.get("id") == sid:
                    return x["id"]
    return None


def route_plugin(route_id, payload):
    # NOTE: nested /services/{s}/routes/{r}/plugins works with IDS; route
    # NAMES in that path 404 in 3.9.4. Use the top-level /routes/{id}/plugins.
    base = "/routes/%s/plugins" % route_id
    code, body = call("GET", base + "?size=100")
    pid = None
    if code == 200 and isinstance(body, dict):
        for x in body.get("data", []):
            if x.get("name") == payload["name"]:
                pid = x["id"]
                break
    if pid:
        code, body = call("PUT", base + "/" + pid, payload)
        if code != 200:
            print("  PUT %s error: %s" % (payload["name"], body))
        return ("updated" if code == 200 else "ERROR"), code
    code, body = call("POST", base, payload)
    if code not in (200, 201):
        print("  POST %s error: %s" % (payload["name"], body))
    return ("created" if code in (200, 201) else "ERROR"), code


# Kong 3.9 post-function runs in a log_by_lua* sandbox that FORBIDS
# require('cjson'); and KONG_LOG_LEVEL=notice suppresses ngx.INFO.
# -> build the JSON string by hand and log at ngx.WARN.
META_LOG = r"""
local function safe(f) local ok, v = pcall(f) return ok and v or nil end
local function q(v)
  if v == nil then return 'null' end
  v = tostring(v)
  v = v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  return '"' .. v .. '"'
end
local function n(v) if v == nil then return 'null' end return tostring(math.floor(tonumber(v) or 0)) end
-- kong.service.request accessors are nil in the LOG phase on 3.9;
-- ngx.var holds them reliably.
local method   = ngx.var.request_method
local path     = ngx.var.uri
local status   = safe(function() return kong.service.response.get_status() end)
local cid      = safe(function() return kong.service.response.get_header('X-Correlation-Id') end)
local consumer = safe(function() local c = kong.client.get_consumer() return c and c.username or nil end)
local dur = math.floor((tonumber(ngx.var.request_time) or 0) * 1000 + 0.5)
ngx.log(ngx.WARN, 'ai-gw-meta: {"ts":' .. n(os.time())
  .. ',"method":' .. q(method)
  .. ',"path":' .. q(path)
  .. ',"status":' .. n(status)
  .. ',"duration_ms":' .. tostring(dur)
  .. ',"correlation_id":' .. q(cid)
  .. ',"consumer":' .. q(consumer) .. '}')
"""

# 1) consumer + key-auth credential (key written to a 600 file, never printed)
st, _ = upsert("consumers", {"username": "ai-consumer", "custom_id": "ai-gw"})
print("consumer ai-consumer:", st)
# NOTE: Kong 3.9.4 uses the SINGULAR per-consumer credential endpoint
# /consumers/{username}/key-auth (the plural /key-auths is 404 here).
code, _ = call("GET", "/consumers/ai-consumer/key-auth?size=1")
key = None
if code == 200 and isinstance(_, dict) and _.get("data"):
    key = _["data"][0].get("key")
    print("key-auth credential: updated (kept existing)")
else:
    key = "ai-" + secrets.token_hex(16)
    code, _ = call("POST", "/consumers/ai-consumer/key-auth", {"key": key})
    assert code in (200, 201), "key-auth create failed: %s" % code
    print("key-auth credential: created (stored on-server)")
os.makedirs(os.path.dirname(creds_file), exist_ok=True)
with open(creds_file, "w") as f:
    f.write("# AI gateway key-auth credential (generated %s)\n"
            "# proxy: 127.0.0.1:18080/ai/*   header: api-key: <key>\n"
            "aikey=%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), key))
os.chmod(creds_file, 0o600)

# 2) service
st, _ = upsert("services", {"name": "ai-gw", "host": ai_host, "port": ai_port,
                            "connect_timeout": 5000, "read_timeout": 60000})
print("service ai-gw (%s:%d): %s" % (ai_host, ai_port, st))
sid = by_name("services", "ai-gw")["id"]

# 3) route /ai (strip_path -> backend sees /v1/*).
#    NOTE: the update payload MUST keep "name" — a PUT without it clears it.
rid = find_route(sid, "ai-gw-v1")
ROUTE = {"name": "ai-gw-v1", "paths": ["/ai"], "strip_path": True,
         "methods": [], "protocols": ["http", "https"]}
if rid:
    code, body = call("PUT", "/services/%s/routes/%s" % (sid, rid), ROUTE)
    if code != 200:
        print("  route PUT error:", body)
    print("route ai-gw-v1:", "updated" if code == 200 else "ERROR")
else:
    code, body = call("POST", "/services/%s/routes" % sid, ROUTE)
    if code not in (200, 201):
        print("  route POST error:", body)
        raise SystemExit("route create failed")
    print("route ai-gw-v1: created")
    rid = find_route(sid, "ai-gw-v1")
assert rid, "route ai-gw-v1 not resolvable after upsert"

# 4) route-scoped plugins (route referenced by ID)
st, _ = route_plugin(rid,
                     {"name": "key-auth",
                      "config": {"key_names": ["api-key", "X-Api-Key"],
                                 "hide_credentials": True}})
print("plugin key-auth:", st)
st, _ = route_plugin(rid,
                     {"name": "rate-limiting",
                      "config": {"policy": "local", "minute": 30, "second": 5}})
print("plugin rate-limiting (local, 30/min 5/s):", st)
st, _ = route_plugin(rid,
                     {"name": "oss-pre",
                      "config": {"correlation_id_header": "X-Correlation-Id"}})
print("plugin oss-pre (correlation id):", st)
st, _ = route_plugin(rid,
                     {"name": "post-function", "config": {"log": [META_LOG]}})
print("plugin post-function (metadata log):", st)

# 5) summary
for kind in ("services", "routes"):
    code, body = call("GET", "/%s?size=500" % kind)
    print("inventory %s: %d" % (kind, len(body.get("data", [])) if isinstance(body, dict) else "?"))
code, body = call("GET", "/plugins?size=500")
n = len(body.get("data", [])) if isinstance(body, dict) else "?"
print("inventory plugins: %d" % n)
print("CREDS: %s (mode 600, key never printed)" % creds_file)
PY
log "AI gateway configured."
