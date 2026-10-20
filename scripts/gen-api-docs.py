#!/usr/bin/env python3
"""Generate a static API documentation page from the live Kong gateway.

Reads the route/service/plugin inventory from the Admin API and renders a
single self-contained HTML file (no external JS/CSS/Swagger dependencies):

  - one section per route (path, methods, service, upstream, plugins)
  - a copy-paste curl example per route (success + how to add an API key)
  - a plain-text "OpenAPI-like" summary table
  - generation timestamp + Kong version (provenance)

Stdlib only. Read-only against the Admin API.

Usage:
    python3 gen-api-docs.py [ADMIN_URL] [OUT_HTML]
    (defaults: http://127.0.0.1:18001  and  ./api-docs.html)

The output is meant to be served statically (e.g. behind the 443 auth gate
on the public host) — it contains NO credentials, keys, or secrets.
"""
import html
import json
import sys
import time
import urllib.request

DEFAULT_ADMIN = "http://127.0.0.1:18001"
DEFAULT_OUT = "api-docs.html"
PROXY_BASE_DEFAULT = "http://127.0.0.1:18080"


def get_json(url):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def collect(admin):
    def coll(name):
        try:
            return get_json("%s/%s?size=500" % (admin, name)).get("data", [])
        except Exception as e:  # noqa: BLE001
            print("warn: could not read %s: %s" % (name, e), file=sys.stderr)
            return []

    return {
        "info": get_json(admin + "/"),
        "services": coll("services"),
        "routes": coll("routes"),
        "plugins": coll("plugins"),
        "upstreams": coll("upstreams"),
    }


def upstream_of(svc, upstreams):
    if not svc:
        return None
    u = svc.get("upstream") or (svc.get("host"), svc.get("port"))
    if isinstance(u, str):
        for x in upstreams:
            if x["name"] == u:
                return {"name": u, "targets": [t.get("target") for t in []]}
        return {"name": u}
    if svc.get("upstream"):
        for x in upstreams:
            if x["name"] == svc.get("upstream"):
                return x
    return {"host": svc.get("host"), "port": svc.get("port")}


def svc_id_of(x):
    """Kong 3.9 reports relations as nested objects ('service': {'id': ...});
    older releases use the 'service_id' scalar. Handle both shapes."""
    if x.get("service_id"):
        return x["service_id"]
    s = x.get("service")
    return s.get("id") if isinstance(s, dict) else None


def render(data, out, proxy_base):
    info = data.get("info", {}) or {}
    version = info.get("version", "?")
    svc_by_id = {s["id"]: s for s in data["services"]}
    up_by_name = {u["name"]: u for u in data["upstreams"]}

    routes = sorted(data["routes"], key=lambda r: (r.get("paths") or [""])[0])
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    sections = []
    table_rows = []
    for r in routes:
        name = r.get("name", "?")
        paths = r.get("paths") or []
        methods = r.get("methods") or ["GET"]
        svc = svc_by_id.get(svc_id_of(r), {})
        sid = svc.get("id")
        plugs = [p for p in data["plugins"] if svc_id_of(p) == sid]
        plug_names = sorted(p["name"] for p in plugs)
        up = upstream_of(svc, data["upstreams"])
        up_desc = ""
        if up:
            if up.get("name"):
                targets = sorted(t.get("target") or "" for t in up.get("targets", []) if isinstance(t, dict))
                up_desc = "upstream %s" % up.get("name") + ((" [%s]" % ", ".join(targets[:4])) if targets else "")
            else:
                up_desc = "%s:%s" % (up.get("host", "?"), up.get("port", "?"))

        p0 = paths[0] if paths else "/"
        curl = "curl -i %s%s" % (proxy_base.rstrip("/"), p0)
        if "POST" in methods and "GET" not in methods:
            curl += " -X POST -H 'Content-Type: application/json' -d '{}'"

        table_rows.append(
            "<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>"
            % (
                html.escape(", ".join(paths)),
                html.escape(", ".join(methods)),
                html.escape(name),
                html.escape(up_desc or "-"),
                html.escape(", ".join(plug_names) or "-"),
            )
        )

        sections.append("""
<div class="card">
<h2 id="%s">%s <span class="m">(%s)</span></h2>
<p class="meta">route <code>%s</code> &middot; service <code>%s</code> &middot; %s</p>
<p class="meta">plugins: %s</p>
<pre>## %s
%s</pre>
<pre>## with an API key header (when the route enforces one)
%s -H 'X-Api-Key: <key>'</pre>
</div>""" % (
            html.escape(name, quote=True),
            html.escape(name),
            ", ".join(methods),
            html.escape(", ".join(paths)),
            html.escape(svc.get("name", "-")),
            up_desc or "upstream n/a",
            html.escape(", ".join(plug_names) or "none"),
            html.escape(name),
            html.escape(curl),
            html.escape(curl),
        ))

    body = """<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kong OSS Gateway - API Catalog</title>
<style>
body{font-family:system-ui,sans-serif;background:#10141a;color:#e6e9ee;margin:0;padding:24px}
h1{font-size:20px}h2{font-size:16px;margin:0 0 6px}
.m{color:#8b98ad;font-weight:400;font-size:13px}
.meta{color:#8b98ad;font-size:13px;margin:2px 0}
pre{background:#0d1117;border:1px solid #232c3b;border-radius:8px;padding:12px;
font-family:ui-monospace,Consolas,monospace;font-size:12.5px;overflow:auto;color:#d7e0ec}
table{border-collapse:collapse;width:100%;font-size:13px;margin:14px 0}
th,td{text-align:left;padding:7px 9px;border-bottom:1px solid #232c3b}
th{color:#8b98ad;font-weight:600}
.card{background:#161c26;border:1px solid #2a3446;border-radius:9px;padding:14px;margin-bottom:12px}
code{background:#0d1117;padding:1px 5px;border-radius:4px;font-size:12.5px}
.banner{background:#1a2029;border:1px solid #2f81f755;border-radius:8px;padding:10px 12px;
font-size:13px;margin:12px 0}
a{color:#79b8ff}
</style></head><body>
<h1>Kong OSS Gateway &mdash; API Catalog</h1>
<p class="meta">Kong @@VERSION@@ &middot; generated @@NOW@@ (UTC) from the live route inventory &middot; static page, no Swagger dependency</p>
<div class="banner">All endpoints are served through the Kong proxy. Requests are
subject to the plugins attached to each route (auth, rate limiting,
transformation). This page contains <b>no credentials or keys</b>; replace
<code><key></code> with a real API key issued to your consumer.</div>
<h2>Route inventory</h2>
<table><thead><tr><th>path</th><th>methods</th><th>route</th><th>upstream</th><th>plugins</th></tr></thead>
<tbody>
@@TABLE@@
</tbody></table>
<h2>Endpoints & curl examples</h2>
@@SECTIONS@@
<p class="meta">Generated by <code>scripts/gen-api-docs.py</code>. Re-run after
configuration changes to refresh this page.</p>
</body></html>
"""
    body = (body.replace("@@VERSION@@", html.escape(str(version)))
               .replace("@@NOW@@", html.escape(now))
               .replace("@@TABLE@@", "\n".join(table_rows))
               .replace("@@SECTIONS@@", "\n".join(sections)))
    with open(out, "w", encoding="utf-8") as f:
        f.write(body)
    print("wrote %s (%d routes, kong %s)" % (out, len(routes), version))


def main(argv):
    admin = argv[1] if len(argv) > 1 else DEFAULT_ADMIN
    out = argv[2] if len(argv) > 2 else DEFAULT_OUT
    proxy_base = argv[3] if len(argv) > 3 else PROXY_BASE_DEFAULT
    data = collect(admin.rstrip("/"))
    render(data, out, proxy_base)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
