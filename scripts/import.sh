#!/usr/bin/env bash
# Kong OSS release — import (apply) a declarative gateway file.
#
# The canonical format is the JSON produced by scripts/export.sh
# (kong-gateway.json). YAML is accepted too (parsed with python3, no deps:
# a minimal YAML-subset reader is NOT included — for YAML, run
# `scripts/yaml2json.py <file>` first, or use the .json twin).
#
# Semantics:
#   - STRICTLY ADDITIVE / IDEMPOTENT: creates missing entities, updates
#     existing ones (matched by `name` for services/upstreams/consumers,
#     by `name` for routes, by (name, service/consumer) for plugins).
#   - It NEVER deletes entities absent from the file (destructive sync is
#     deliberately out of scope; do that explicitly if needed).
#   - Kong 3.9 relation quirks are handled: routes and plugins are
#     created/updated through the nested endpoints
#     POST/PUT /services/{id}/routes|plugins (a top-level PUT would null
#     the service relation).
#
# Usage:
#   scripts/import.sh <file.json>            # apply
#   scripts/import.sh <file.json> --dry-run  # show what would change
source "$(dirname "$0")/_common.sh"

require_cmd curl
PY=python3

FILE="${1:-}"
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1
[ -n "$FILE" ] || die "usage: import.sh <kong-gateway.json> [--dry-run]"
[ -f "$FILE" ] || die "file not found: $FILE"

log "importing $FILE (dry-run=$DRY) -> $ADMIN_URL"

$PY - "$ADMIN_URL" "$FILE" "$DRY" <<'PYEOF'
import json, sys, urllib.request

ADMIN, FILE, DRY = sys.argv[1], sys.argv[2], int(sys.argv[3])

doc = json.load(open(FILE))

def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(ADMIN + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            try:
                return r.status, (json.loads(raw) if raw else {})
            except ValueError:
                return r.status, raw.decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, (json.loads(raw) if raw else {})
        except ValueError:
            return e.code, raw.decode("utf-8", "replace")[:400]

stats = {"created": 0, "updated": 0, "unchanged": 0, "errors": 0}
errors = []

def say(action, what, note=""):
    # Counts are recorded even in dry-run (they describe what WOULD happen);
    # the summary line is labelled accordingly.
    print("  [%s] %s %s" % (action, what, note))
    if action == "created":
        stats["created"] += 1
    elif action == "updated":
        stats["updated"] += 1
    elif action == "unchanged":
        stats["unchanged"] += 1
    elif action == "ERROR":
        stats["errors"] += 1
        errors.append(what + " " + note)

def jget(d, key, default=None):
    v = d.get(key)
    return v if v not in (None, "") else default

def same(cur, payload):
    """True if existing entity `cur` already matches `payload` (ignoring
    null/None differences) — lets dry-run report `unchanged` honestly."""
    for k, v in payload.items():
        if v is None:
            continue
        if cur.get(k) != v:
            return False
    return True

# ---- services -------------------------------------------------------------
svc_ids = {}
for s in doc.get("services", []):
    name = s["name"]
    code, cur = call("GET", "/services/" + name)
    payload = {"name": name,
               "protocol": jget(s, "protocol", "http"),
               "host": jget(s, "host"),
               "port": jget(s, "port", 80)}
    for k in ("path", "retries", "connect_timeout", "read_timeout", "write_timeout"):
        if k in s:
            payload[k] = s[k]
    if s.get("tags"):
        payload["tags"] = s["tags"]
    if not jget(s, "host"):
        payload.pop("host", None)
        # a hostless service (upstream-bound) must not get a default port
        payload.pop("port", None)
    if code == 200:
        if not DRY and not same(cur, payload):
            call("PUT", "/services/" + cur["id"], payload)
        say("unchanged" if same(cur, payload) else "updated", "service " + name)
        svc_ids[name] = cur["id"]
    else:
        if not DRY:
            code2, res = call("POST", "/services", payload)
            if code2 in (200, 201):
                svc_ids[name] = res["id"]
                say("created", "service " + name)
            else:
                say("ERROR", "service " + name, "POST -> %s %s" % (code2, res))
        else:
            say("created", "service " + name)

# ---- consumers -------------------------------------------------------------
cons_ids = {}
for c in doc.get("consumers", []):
    uname = c["username"]
    code, cur = call("GET", "/consumers/" + uname)
    payload = {"username": uname}
    if c.get("custom_id"):
        payload["custom_id"] = c["custom_id"]
    if c.get("tags"):
        payload["tags"] = c["tags"]
    if code == 200:
        if not DRY and not same(cur, payload):
            call("PUT", "/consumers/" + cur["id"], payload)
        say("unchanged" if same(cur, payload) else "updated", "consumer " + uname)
        cons_ids[uname] = cur["id"]
    else:
        if not DRY:
            code2, res = call("POST", "/consumers", payload)
            if code2 in (200, 201):
                cons_ids[uname] = res["id"]
            say("created" if code2 in (200, 201) else "ERROR", "consumer " + uname,
                "" if code2 in (200, 201) else "POST -> %s %s" % (code2, res))
        else:
            say("created", "consumer " + uname)

# ---- routes ----------------------------------------------------------------
for r in doc.get("routes", []):
    name = r["name"]
    svc = r.get("_service")
    s_code, s_cur = call("GET", "/services/" + svc) if svc else (404, None)
    if s_code != 200:
        say("ERROR", "route " + name, "service '%s' not found" % svc)
        continue
    sid = s_cur["id"]
    # find existing route by name under this service
    code, lst = call("GET", "/services/%s/routes?size=100" % sid)
    rid = None
    if code == 200:
        for x in lst.get("data", []):
            if x["name"] == name:
                rid = x["id"]
                break
    payload = {"name": name, "paths": jget(r, "paths", [])}
    for k in ("methods", "hosts", "strip_path", "preserve_host",
              "https_redirect_status_code", "regex_priority", "protocols",
              "request_buffering", "response_buffering", "tags"):
        if k in r:
            payload[k] = r[k]
    if rid:
        # find the existing route object for a real diff
        rcur = None
        if code == 200:
            for x in lst.get("data", []):
                if x["name"] == name:
                    rcur = x
                    break
        if not DRY and not same(rcur or {}, payload):
            call("PUT", "/services/%s/routes/%s" % (sid, rid), payload)
        say("unchanged" if same(rcur or {}, payload) else "updated",
            "route " + name, "(%s -> %s)" % (svc, ",".join(payload["paths"])))
    else:
        if not DRY:
            code2, res = call("POST", "/services/%s/routes" % sid, payload)
            say("created" if code2 in (200, 201) else "ERROR", "route " + name,
                "" if code2 in (200, 201) else "POST -> %s %s" % (code2, res))
        else:
            say("created", "route " + name, "(%s -> %s)" % (svc, ",".join(payload["paths"])))

# ---- plugins ---------------------------------------------------------------
for p in doc.get("plugins", []):
    name = p["name"]
    svc = p.get("_service")
    route = p.get("_route")
    consumer = p.get("_consumer")
    payload = {"name": name}
    if p.get("config") is not None:
        payload["config"] = p["config"]
    if p.get("enabled") is not None:
        payload["enabled"] = p["enabled"]
    if p.get("tags"):
        payload["tags"] = p["tags"]

    if svc:
        s_code, s_cur = call("GET", "/services/" + svc)
        if s_code != 200:
            say("ERROR", "plugin %s" % name, "service '%s' not found" % svc)
            continue
        sid = s_cur["id"]
        code, lst = call("GET", "/services/%s/plugins?size=100" % sid)
        pid = pcur = None
        if code == 200:
            for x in lst.get("data", []):
                if x["name"] == name:
                    pid, pcur = x["id"], x
                    break
        where = "plugin %s on service %s" % (name, svc)
        if pid:
            if not DRY and not same(pcur, payload):
                call("PUT", "/services/%s/plugins/%s" % (sid, pid), payload)
            say("unchanged" if same(pcur, payload) else "updated", where)
        else:
            if not DRY:
                code2, res = call("POST", "/services/%s/plugins" % sid, payload)
                say("created" if code2 in (200, 201) else "ERROR", where,
                    "" if code2 in (200, 201) else "POST -> %s %s" % (code2, res))
            else:
                say("created", where)
    elif route:
        r_code, r_cur = call("GET", "/routes/" + route)
        if r_code != 200:
            say("ERROR", "plugin %s" % name, "route '%s' not found" % route)
            continue
        rid = r_cur["id"]
        code, lst = call("GET", "/routes/%s/plugins?size=100" % rid)
        pid = pcur = None
        if code == 200:
            for x in lst.get("data", []):
                if x["name"] == name:
                    pid, pcur = x["id"], x
                    break
        where = "plugin %s on route %s" % (name, route)
        if pid:
            if not DRY and not same(pcur, payload):
                call("PUT", "/routes/%s/plugins/%s" % (rid, pid), payload)
            say("unchanged" if same(pcur, payload) else "updated", where)
        else:
            if not DRY:
                code2, res = call("POST", "/routes/%s/plugins" % rid, payload)
                say("created" if code2 in (200, 201) else "ERROR", where,
                    "" if code2 in (200, 201) else "POST -> %s %s" % (code2, res))
            else:
                say("created", where)
    elif consumer:
        c_code, c_cur = call("GET", "/consumers/" + consumer)
        if c_code != 200:
            say("ERROR", "plugin %s" % name, "consumer '%s' not found" % consumer)
            continue
        cid = c_cur["id"]
        code, lst = call("GET", "/consumers/%s/plugins?size=100" % cid)
        pid = pcur = None
        if code == 200:
            for x in lst.get("data", []):
                if x["name"] == name:
                    pid, pcur = x["id"], x
                    break
        where = "plugin %s on consumer %s" % (name, consumer)
        if pid:
            if not DRY and not same(pcur, payload):
                call("PUT", "/consumers/%s/plugins/%s" % (cid, pid), payload)
            say("unchanged" if same(pcur, payload) else "updated", where)
        else:
            if not DRY:
                code2, res = call("POST", "/consumers/%s/plugins" % cid, payload)
                say("created" if code2 in (200, 201) else "ERROR", where,
                    "" if code2 in (200, 201) else "POST -> %s %s" % (code2, res))
            else:
                say("created", where)
    else:
        # global plugin — CRITICAL: a plugin is only global when it has NO
        # relation at all. Kong 3.9 reports relations as nested objects
        # (service/consumer/route), not *_id scalars; match both forms,
        # otherwise service-scoped plugins get mistaken for global ones
        # and a top-level PUT would clobber their config.
        def is_global(x):
            return not any(x.get(k) for k in
                           ("service_id", "service", "consumer_id", "consumer",
                            "route_id", "route"))
        code, lst = call("GET", "/plugins?size=100")
        pid = pcur = None
        if code == 200:
            for x in lst.get("data", []):
                if x["name"] == name and is_global(x):
                    pid, pcur = x["id"], x
                    break
        where = "global plugin " + name
        if pid:
            if not DRY and not same(pcur, payload):
                call("PUT", "/plugins/%s" % pid, payload)
            say("unchanged" if same(pcur, payload) else "updated", where)
        else:
            if not DRY:
                code2, res = call("POST", "/plugins", payload)
                say("created" if code2 in (200, 201) else "ERROR", where,
                    "" if code2 in (200, 201) else "POST -> %s %s" % (code2, res))
            else:
                say("created", where)

# ---- upstreams -------------------------------------------------------------
up_ids = {}
for u in doc.get("upstreams", []):
    name = u["name"]
    code, cur = call("GET", "/upstreams/" + name)
    payload = {"name": name}
    for k in ("slots", "host_header", "algorithm", "tags"):
        if k in u:
            payload[k] = u[k]
    if code == 200:
        if not DRY and not same(cur, payload):
            call("PUT", "/upstreams/" + cur["id"], payload)
        say("unchanged" if same(cur, payload) else "updated", "upstream " + name)
        up_ids[name] = cur["id"]
    else:
        if not DRY:
            code2, res = call("POST", "/upstreams", payload)
            if code2 in (200, 201):
                up_ids[name] = res["id"]
            say("created" if code2 in (200, 201) else "ERROR", "upstream " + name,
                "" if code2 in (200, 201) else "POST -> %s %s" % (code2, res))
        else:
            say("created", "upstream " + name)

# ---- targets ---------------------------------------------------------------
for t in doc.get("targets", []):
    up = t.get("_upstream")
    tgt = t.get("target")
    if not up or not tgt:
        say("ERROR", "target " + str(tgt), "missing _upstream or target")
        continue
    u_code, u_cur = call("GET", "/upstreams/" + up)
    if u_code != 200:
        say("ERROR", "target " + tgt, "upstream '%s' not found" % up)
        continue
    uid = u_cur["id"]
    code, lst = call("GET", "/upstreams/%s/targets?size=100" % uid)
    tid = tcur = None
    if code == 200:
        for x in lst.get("data", []):
            if x.get("target") == tgt:
                tid, tcur = x["id"], x
                break
    payload = {"target": tgt, "weight": jget(t, "weight", 100)}
    if t.get("tags"):
        payload["tags"] = t["tags"]
    where = "target %s on upstream %s" % (tgt, up)
    if tid:
        if not DRY and not same(tcur, payload):
            call("PUT", "/upstreams/%s/targets/%s" % (uid, tid), payload)
        say("unchanged" if same(tcur, payload) else "updated", where)
    else:
        if not DRY:
            code2, res = call("POST", "/upstreams/%s/targets" % uid, payload)
            say("created" if code2 in (200, 201) else "ERROR", where,
                "" if code2 in (200, 201) else "POST -> %s %s" % (code2, res))
        else:
            say("created", where)

print("  summary: %s=%d updated=%d unchanged=%d errors=%d" % (
    "would create" if DRY else "created",
    stats["created"], stats["updated"], stats["unchanged"], stats["errors"]))
if errors:
    print("  first errors:")
    for e in errors[:10]:
        print("    " + e)
    sys.exit(1)
if DRY:
    print("  (dry-run: nothing was applied)")
PYEOF
