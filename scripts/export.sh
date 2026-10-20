#!/usr/bin/env bash
# Kong OSS release — export the live gateway config as a declarative file.
#
# Reads every entity from the Admin API and writes a decK-style declarative
# file to <OUT_DIR>/kong-gateway.{json,yml} (default OUT_DIR: ../_export).
#   - kong-gateway.json : canonical, machine-readable (JSON is valid YAML,
#                         so deck/Kong decK-style tooling can read it too)
#   - kong-gateway.yml  : human/Git-friendly rendering of the same content
#
# Usage:
#   scripts/export.sh                 # writes ../_export/kong-gateway.{json,yml}
#   OUT_DIR=/tmp/exp scripts/export.sh
#
# Re-runnable; read-only against the Admin API.
source "$(dirname "$0")/_common.sh"

require_cmd curl
PY=python3

: "${OUT_DIR:=$ROOT_DIR/_export}"
mkdir -p "$OUT_DIR"

log "exporting from $ADMIN_URL -> $OUT_DIR"

# Fetch all collections (size=500 per page; Kong demo configs are small).
# NOTE: Kong 3.9 has no top-level /targets endpoint — targets are fetched
# per-upstream via GET /upstreams/{name}/targets (which returns
# {"targets": [...]}, not {"data": [...]}).
fetch_all() { # $1 = collection name
  curl -fsS "$ADMIN_URL/$1?size=500"
}

fetch_all services > /tmp/kx-services.json  || die "failed to fetch services"
fetch_all routes   > /tmp/kx-routes.json    || die "failed to fetch routes"
fetch_all plugins  > /tmp/kx-plugins.json   || die "failed to fetch plugins"
fetch_all consumers > /tmp/kx-consumers.json || die "failed to fetch consumers"
fetch_all upstreams > /tmp/kx-upstreams.json || die "failed to fetch upstreams"

{
  for u in $(python3 -c 'import json; [print(u["name"]) for u in json.load(open("/tmp/kx-upstreams.json")).get("data", [])]'); do
    curl -fsS "$ADMIN_URL/upstreams/$u/targets?size=500"
  done
} > /tmp/kx-targets-raw.jsonl || die "failed to fetch targets"

python3 - <<'PY' || die "failed to merge targets"
import json
out = []
with open("/tmp/kx-targets-raw.jsonl") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        out.extend(json.loads(line).get("targets", []))
with open("/tmp/kx-targets.json", "w") as f:
    json.dump({"data": out}, f)
PY
rm -f /tmp/kx-targets-raw.jsonl

$PY - "$ADMIN_URL" "$OUT_DIR" <<'PYEOF'
import json, sys, time

admin_url, out_dir = sys.argv[1], sys.argv[2]

def load(p):
    with open(p) as f:
        return json.load(f).get("data", [])

services  = load("/tmp/kx-services.json")
routes    = load("/tmp/kx-routes.json")
plugins   = load("/tmp/kx-plugins.json")
consumers = load("/tmp/kx-consumers.json")
upstreams = load("/tmp/kx-upstreams.json")
targets   = load("/tmp/kx-targets.json")

svc_by_id  = {s["id"]: s["name"] for s in services}
up_by_id   = {u["id"]: u["name"] for u in upstreams}
cons_by_id = {c["id"]: c["username"] for c in consumers}
route_by_id = {r["id"]: r["name"] for r in routes}

# Kong 3.9 returns relations as NESTED objects ({"service": {"id": ...}});
# older/other deployments use *_id scalars. Handle both.
def svc_of(x):
    if x.get("service_id"):
        return x["service_id"]
    s = x.get("service")
    return s.get("id") if isinstance(s, dict) else None

def cons_of(x):
    if x.get("consumer_id"):
        return x["consumer_id"]
    c = x.get("consumer")
    return c.get("id") if isinstance(c, dict) else None

def route_of(x):
    if x.get("route_id"):
        return x["route_id"]
    r = x.get("route")
    return r.get("id") if isinstance(r, dict) else None

def keep(d, keys):
    out = {}
    for k in keys:
        if k in d and d[k] not in (None, [], {}):
            out[k] = d[k]
    return out

SVC_KEYS = ["protocol", "host", "port", "path", "retries", "connect_timeout",
            "read_timeout", "write_timeout", "tags"]
ROUTE_KEYS = ["hosts", "methods", "strip_path", "preserve_host",
              "https_redirect_status_code", "regex_priority", "protocols",
              "request_buffering", "response_buffering", "tags"]
PLUG_KEYS = ["enabled", "config", "tags"]
TGT_KEYS = ["target", "weight", "tags"]

doc = {"_format_version": "3.0"}

sv = []
for s in sorted(services, key=lambda x: x["name"]):
    e = {"name": s["name"]}
    e.update(keep(s, SVC_KEYS))
    sv.append(e)
doc["services"] = sv

rs = []
for r in sorted(routes, key=lambda x: x["name"]):
    e = {"name": r["name"]}
    e["paths"] = r.get("paths") or []
    sid = svc_of(r)
    if sid and sid in svc_by_id:
        e["_service"] = svc_by_id[sid]
    e.update(keep(r, ROUTE_KEYS))
    rs.append(e)
doc["routes"] = rs

cs = []
for c in sorted(consumers, key=lambda x: x["username"]):
    e = {"username": c["username"]}
    if c.get("custom_id"):
        e["custom_id"] = c["custom_id"]
    if c.get("tags"):
        e["tags"] = c["tags"]
    cs.append(e)
doc["consumers"] = cs

ps = []
for p in sorted(plugins, key=lambda x: (str(svc_of(x) or ""), str(route_of(x) or ""), x["name"])):
    e = {"name": p["name"]}
    sid = svc_of(p)
    if sid and sid in svc_by_id:
        e["_service"] = svc_by_id[sid]
    rid = route_of(p)
    if rid and rid in route_by_id:
        e["_route"] = route_by_id[rid]
    cid = cons_of(p)
    if cid:
        e["_consumer"] = cons_by_id.get(cid, "unknown-%s" % cid)
    e.update(keep(p, PLUG_KEYS))
    ps.append(e)
doc["plugins"] = ps

us = []
for u in sorted(upstreams, key=lambda x: x["name"]):
    e = {"name": u["name"]}
    e.update(keep(u, ["slots", "host_header", "algorithm", "tags"]))
    us.append(e)
doc["upstreams"] = us

ts = []
for t in sorted(targets, key=lambda x: (str(x.get("upstream_id") or ""), x.get("target") or "")):
    e = {}
    if t.get("upstream_id") and t["upstream_id"] in up_by_id:
        e["_upstream"] = up_by_id[t["upstream_id"]]
    e.update(keep(t, TGT_KEYS))
    ts.append(e)
doc["targets"] = ts

with open(out_dir + "/kong-gateway.json", "w") as f:
    json.dump(doc, f, indent=2, sort_keys=False)
    f.write("\n")

# ---- minimal YAML rendering (JSON is a subset of YAML; emit proper YAML) ---
def esc(s):
    s = str(s)
    if s == "":
        return '""'
    special = any(ch in s for ch in ':#{}[],&*!|>\'"%@`')
    low = s.lower()
    if s in ("true", "false", "null", "yes", "no", "on", "off") or low in ("true", "false", "null"):
        return '"%s"' % s
    try:
        float(s)
        return '"%s"' % s
    except ValueError:
        pass
    if s != s.strip() or s.startswith("- ") or s == "-":
        return '"%s"' % s
    if special:
        return '"%s"' % s.replace('\\', '\\\\').replace('"', '\\"')
    return s

def emit(v, ind):
    pad = "  " * ind
    lines = []
    if isinstance(v, dict):
        if not v:
            return pad + "{}"
        for k, val in v.items():
            if isinstance(val, (dict, list)) and val:
                lines.append("%s%s:" % (pad, k))
                lines.extend(emit(val, ind + 1))
            elif isinstance(val, dict):
                lines.append("%s%s: {}" % (pad, k))
            elif isinstance(val, list):
                lines.append("%s%s: []" % (pad, k))
            else:
                lines.append("%s%s: %s" % (pad, k, emit_scalar(val)))
        return lines
    if isinstance(v, list):
        for item in v:
            if isinstance(item, (dict, list)) and item:
                sub = emit(item, ind + 1)
                first = sub[0].lstrip()
                lines.append("%s- %s" % (pad, first))
                lines.extend(sub[1:])
            else:
                lines.append("%s- %s" % (pad, emit_scalar(item)))
        return lines
    return [pad + emit_scalar(v)]

def emit_scalar(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    return esc(v)

out = []
out.append("_format_version: \"3.0\"")
for key in ("services", "routes", "consumers", "plugins", "upstreams", "targets"):
    items = doc.get(key, [])
    if items:
        out.append("%s:" % key)
        out.extend(emit(items, 1))
    else:
        out.append("%s: []" % key)
out.append("# generated by scripts/export.sh from %s at %s (UTC)" % (
    admin_url, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
with open(out_dir + "/kong-gateway.yml", "w") as f:
    f.write("\n".join(out) + "\n")

print("  services=%d routes=%d consumers=%d plugins=%d upstreams=%d targets=%d" % (
    len(doc["services"]), len(doc["routes"]), len(doc["consumers"]),
    len(doc["plugins"]), len(doc["upstreams"]), len(doc["targets"])))
PYEOF

rm -f /tmp/kx-services.json /tmp/kx-routes.json /tmp/kx-plugins.json \
      /tmp/kx-consumers.json /tmp/kx-upstreams.json /tmp/kx-targets.json
log "wrote $OUT_DIR/kong-gateway.json and $OUT_DIR/kong-gateway.yml"
log "import with:  scripts/import.sh $OUT_DIR/kong-gateway.json"
