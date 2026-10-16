#!/usr/bin/env python3
"""Kong OSS release — mandatory test suite (18 tests).

Runs from the HOST that runs the compose stack (needs: python3 stdlib,
curl, docker CLI). Talks to the loopback proxy + admin API only.

Usage:
  python3 tests/test_suite.py [PROXY_URL] [ADMIN_URL] [BACKEND_NAME]

Defaults:
  PROXY_URL    http://127.0.0.1:18080
  ADMIN_URL    http://127.0.0.1:18001
  BACKEND_NAME oss-echo

Test map (matches the release spec):
  T01  PostgreSQL + Kong + Echo containers up and healthy
  T02  Kong health check (proxy /status + container healthcheck)
  T03  Service + Route creation verified (Admin API)
  T04  Direct Echo request (inside the network, bypassing Kong)
  T05  Echo request via Kong (baseline route)
  T06  oss-pre plugin function (auth + correlation id + body rename)
  T07  oss-post plugin function (response header + body rename + chunked)
  T08  Request header change (request-transformer replace)
  T09  Request JSON field change (request-transformer replace body)
  T10  Authentication: valid X-Api-Key accepted
  T11  Unauthorized request rejected (400 controlled JSON)
  T12  Invalid payload handled (no 500, clean pass-through)
  T13  100 simple requests through Kong
  T14  100 requests with plugins enabled
  T15  Latency statistics (p50/p95/p99) for the baseline route
  T16  Error rate over a 200-request mixed load
  T17  Restart / stability test (delegates to scripts/restart-test.sh)
  T18  Admin API not exposed outside loopback

Writes: tests/results/test-suite-report.txt and tests/results/test-suite.json
Exit code 0 only if all tests pass.
"""
import json
import os
import shlex
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

PROXY = os.environ.get("PROXY_URL", sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:18080")
ADMIN = os.environ.get("ADMIN_URL", sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:18001")
BACKEND = os.environ.get("ECHO_BACKEND_NAME", sys.argv[3] if len(sys.argv) > 3 else "oss-echo")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RESULTS = os.path.join(HERE, "results")
os.makedirs(RESULTS, exist_ok=True)

RESTART_SCRIPT = os.path.join(ROOT, "scripts", "restart-test.sh")

RESULTS_LIST = []


def record(tid, desc, ok, detail, skipped=False):
    verdict = "SKIP" if skipped else ("PASS" if ok else "FAIL")
    RESULTS_LIST.append({"id": tid, "desc": desc, "verdict": verdict,
                         "detail": detail})
    print(f"{verdict}  {tid}  {desc}")
    if not ok and not skipped:
        print(f"      detail: {json.dumps(detail, default=str)[:600]}")


def req(method, url, headers=None, data=None, timeout=30):
    """Do one request; return (status, resp_headers, body_bytes)."""
    body = data.encode("utf-8") if isinstance(data, str) else (data or None)
    r = urllib.request.Request(url, data=body, method=method)
    for k, v in (headers or {}).items():
        r.add_header(k, v)
    if body is not None and not (headers or {}).get("Content-Type"):
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def j(body):
    try:
        return json.loads(body.decode("utf-8"))
    except Exception:
        return None


def hdr(h, name):
    for k, v in h.items():
        if k.lower() == name.lower():
            return v
    return None


def sh(cmd, timeout=120):
    """Run a shell command; return (rc, stdout+stderr)."""
    p = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                       timeout=timeout)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def container_state(name):
    rc, out = sh(f"docker inspect --format '{{{{.State.Status}}}}' {name} 2>/dev/null")
    return out.strip() if rc == 0 else "missing"


def container_health(name):
    rc, out = sh(
        "docker inspect --format "
        "'{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "
        f"{name} 2>/dev/null")
    return out.strip() if rc == 0 else "unknown"


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    k = max(1, min(len(sorted_vals), int(round(p / 100.0 * len(sorted_vals)))))
    return sorted_vals[k - 1]


# ------------------------------------------------------------------ T01
def t01():
    """PG + Kong + Echo containers up and healthy."""
    db = container_state("kong-gw-oss-db")
    kong = container_state("kong-gw-oss-kong")
    echo = container_state("kong-gw-oss-echo")
    db_h = container_health("kong-gw-oss-db")
    kong_h = container_health("kong-gw-oss-kong")
    ok = (db == "running" and kong == "running" and echo == "running"
          and db_h == "healthy" and kong_h == "healthy")
    record("T01", "PostgreSQL + Kong + Echo containers up and healthy",
           ok, {"db": db, "db_health": db_h,
                "kong": kong, "kong_health": kong_h, "echo": echo})


# ------------------------------------------------------------------ T02
def t02():
    """Kong health check: Admin API /status (ok) + root (version).

    NOTE: the proxy port has no /status route (only admin), so the
    proxy side is validated via a baseline /test-echo request instead.
    """
    st1, h1, b1 = req("GET", ADMIN + "/status")
    st2, h2, b2 = req("GET", ADMIN + "/")
    st3, h3, b3 = req("GET", PROXY + "/test-echo")
    d1, d2 = j(b1), j(b2)
    # Kong 3.9.x admin /status returns {database, memory, server} —
    # the health signal is database.reachable (not a top-level "status" key).
    db_ok = isinstance(d1, dict) and d1.get("database", {}).get("reachable") is True \
        and isinstance(d1.get("server"), dict)
    ok = (st1 == 200 and db_ok
          and st2 == 200 and isinstance(d2, dict) and "version" in d2
          and st3 == 200)
    record("T02", "Kong health check (admin /status + Admin API + proxy baseline)",
           ok, {"admin_status": st1, "database_reachable":
                (d1 or {}).get("database", {}).get("reachable"),
                "admin_version": d2.get("version") if d2 else None,
                "proxy_baseline": st3})


# ------------------------------------------------------------------ T03
def t03():
    """Services and routes created (verify the configured layout)."""
    st, h, b = req("GET", ADMIN + "/services?size=100")
    d = j(b) or {}
    services = {s["name"]: s for s in d.get("data", [])}
    st, h, b = req("GET", ADMIN + "/routes?size=100")
    d = j(b) or {}
    routes = {r["name"]: r for r in d.get("data", [])}
    want_services = ["test-echo-svc", "t-req-header-svc", "t-req-json-svc",
                     "t-resp-header-svc", "t-resp-json-svc", "t-resp-edge-svc",
                     "t-pre-svc", "t-post-svc", "secure-echo-svc", "combined-svc"]
    want_routes = ["/test-echo", "/t-req-header", "/t-req-json", "/t-resp-header",
                   "/fixed-ok", "/empty", "/not-json", "/echo-error",
                   "/t-pre", "/t-post", "/secure-echo", "/combined-echo"]
    missing_svc = [s for s in want_services if s not in services]
    all_paths = set()
    for r in routes.values():
        all_paths.update(r.get("paths") or [])
    missing_rt = [p for p in want_routes if p not in all_paths]
    ok = not missing_svc and not missing_rt
    record("T03", "Service + Route creation verified via Admin API",
           ok, {"services_found": len(services), "routes_found": len(routes),
                "missing_services": missing_svc, "missing_routes": missing_rt})


# ------------------------------------------------------------------ T04
def t04():
    """Direct Echo request inside the network (bypassing Kong)."""
    rc, out = sh(
        "docker exec kong-gw-oss-echo wget -qO- "
        "http://127.0.0.1:9000/health 2>/dev/null", timeout=30)
    d = j(out.encode())
    ok = rc == 0 and isinstance(d, dict) and d.get("status") == "ok" \
        and d.get("backend") == BACKEND
    record("T04", "Direct Echo request (internal network, no Kong)",
           ok, {"rc": rc, "body": d})


# ------------------------------------------------------------------ T05
def t05():
    """Echo request via Kong on the baseline route."""
    st, h, b = req("GET", PROXY + "/test-echo?name=via-kong")
    d = j(b)
    ok = (st == 200 and isinstance(d, dict)
          and d.get("backend") == BACKEND
          and d.get("method") == "GET"
          and d.get("query", {}).get("name") == "via-kong")
    record("T05", "Echo request via Kong (baseline /test-echo)",
           ok, {"status": st, "backend": d.get("backend") if d else None,
                "query": d.get("query") if d else None})


# ------------------------------------------------------------------ T06
def t06():
    """oss-pre: auth + correlation id generated + request body rename."""
    st, h, b = req("POST", PROXY + "/t-pre",
                   headers={"X-Api-Key": "t06"},
                   data=json.dumps({"customer_id": 42, "note": "t06"}))
    d = j(b)
    up = d.get("body") if isinstance(d, dict) else None
    cid = hdr(h, "X-Correlation-Id")
    # the echo backend puts the received request headers in the TOP-LEVEL
    # "headers" object of its payload (not inside "body")
    upstream_cid = d.get("headers", {}).get("X-Correlation-Id") if isinstance(d, dict) else None
    ok = (st == 200
          and isinstance(up, dict)
          and up.get("customerId") == 42
          and "customer_id" not in up
          and up.get("note") == "t06"
          and upstream_cid
          and isinstance(cid, str) and cid.startswith("oss-")
          and cid == upstream_cid)
    record("T06", "oss-pre plugin (required header + correlation id + body rename)",
           ok, {"status": st, "upstream_body": up, "cid_header": cid,
                "upstream_cid": upstream_cid})


# ------------------------------------------------------------------ T07
def t07():
    """oss-post: response header + JSON rename + correlation echo + chunked."""
    # /fixed-ok: upstream {"status":"ok",...} -> client {"success":"ok",...}
    st1, h1, b1 = req("GET", PROXY + "/fixed-ok")
    d1 = j(b1)
    # /t-post: upstream "backend" key -> client "gateway" key
    st2, h2, b2 = req("POST", PROXY + "/t-post",
                      data=json.dumps({"x": 1}))
    d2 = j(b2)
    ok = (st1 == 200 and isinstance(d1, dict)
          and d1.get("success") == "ok" and "status" not in d1
          and d1.get("data", {}).get("id") == 123
          and hdr(h1, "X-Oss-Post") == "processed"
          and "chunked" in (hdr(h1, "Transfer-Encoding") or "").lower()
          and st2 == 200 and isinstance(d2, dict)
          and d2.get("gateway") == BACKEND
          and "backend" not in d2
          and hdr(h2, "X-Oss-Post") == "processed"
          and hdr(h2, "X-Correlation-Id")
          and hdr(h2, "X-Correlation-Id") == d2.get("headers", {}).get("X-Correlation-Id"))
    record("T07", "oss-post plugin (resp header + rename + correlation echo + chunked)",
           ok, {"fixed_ok": d1, "x_oss_post": hdr(h1, "X-Oss-Post"),
                "t_post_backend_key": d2.get("gateway") if isinstance(d2, dict) else None,
                "cid": hdr(h2, "X-Correlation-Id")})


# ------------------------------------------------------------------ T08
def t08():
    """Request header change: X-Client-Type legacy -> modern upstream."""
    st, h, b = req("POST", PROXY + "/t-req-header",
                   headers={"X-Client-Type": "legacy"},
                   data=json.dumps({"a": 1}))
    d = j(b)
    st2, h2, b2 = req("GET", PROXY + "/test-echo?ctl=1",
                      headers={"X-Client-Type": "legacy"})
    d2 = j(b2)
    upstream_ht = d.get("headers", {}).get("X-Client-Type") if d else None
    ctl_ht = d2.get("headers", {}).get("X-Client-Type") if d2 else None
    ok = (st == 200 and upstream_ht == "modern"
          and st2 == 200 and ctl_ht == "legacy")
    record("T08", "Request header change (request-transformer replace) + control",
           ok, {"upstream_saw": upstream_ht, "control_saw": ctl_ht})


# ------------------------------------------------------------------ T09
def t09():
    """Request JSON field change: old keys removed + body replaced.

    NOTE (Kong 3.9.4 semantics): request-transformer body arrays take
    colon "key:value" string pairs whose values are rendered as STRINGS
    and merged into the parsed JSON body (the legacy JSON-map form from
    Kong <= 3.4 is gone). `replace.body` only overwrites EXISTING keys,
    so configure.sh removes the original keys and adds the new ones via
    `add.body` with ["customerId:123", "name:Ali"] (no space after the
    colon — the value is the raw remainder after it).
    """
    st, h, b = req("POST", PROXY + "/t-req-json",
                   data=json.dumps({"customer_id": 999, "anything": "goes"}))
    d = j(b)
    st2, h2, b2 = req("POST", PROXY + "/test-echo",
                      data=json.dumps({"customer_id": 999}))
    d2 = j(b2)
    up_body = d.get("body") if isinstance(d, dict) else None
    ctl_body = d2.get("body") if isinstance(d2, dict) else None
    ok = (st == 200
          and isinstance(up_body, dict)
          and up_body.get("customerId") == "123"
          and up_body.get("name") == "Ali"
          and "customer_id" not in up_body
          and "anything" not in up_body
          and st2 == 200 and ctl_body == {"customer_id": 999})
    record("T09", "Request JSON body change (request-transformer remove+replace) + control",
           ok, {"upstream_body": up_body, "control_body": ctl_body})


# ------------------------------------------------------------------ T10
def t10():
    """Authentication: valid X-Api-Key is accepted (200)."""
    st, h, b = req("POST", PROXY + "/secure-echo",
                   headers={"X-Api-Key": "valid-key-t10"},
                   data=json.dumps({"who": "t10"}))
    d = j(b)
    ok = st == 200 and isinstance(d, dict) and d.get("body") == {"who": "t10"}
    record("T10", "Authentication: request WITH X-Api-Key accepted",
           ok, {"status": st, "body": d.get("body") if d else None})


# ------------------------------------------------------------------ T11
def t11():
    """Unauthorized request rejected with 400 controlled JSON."""
    st, h, b = req("POST", PROXY + "/secure-echo",
                   data=json.dumps({"who": "anonymous"}))
    d = j(b)
    # control: same request WITH the key must pass
    st2, _, _ = req("POST", PROXY + "/secure-echo",
                    headers={"X-Api-Key": "k"}, data=json.dumps({"a": 1}))
    ok = (st == 400 and isinstance(d, dict)
          and d.get("error") == "missing_required_header"
          and d.get("header") == "X-Api-Key"
          and st2 == 200)
    record("T11", "Unauthorized request rejected (400 controlled JSON, no leak)",
           ok, {"status": st, "error_body": d, "control_with_key": st2})


# ------------------------------------------------------------------ T12
def t12():
    """Invalid payload: malformed JSON passes through, no 500."""
    bad = '{"broken": ' + 'x' * 5000 + ' }'
    st, h, b = req("POST", PROXY + "/t-pre",
                   headers={"X-Api-Key": "t12"}, data=bad)
    d = j(b)
    ok = (st == 200 and isinstance(d, dict)
          and d.get("body") == bad
          and d.get("body_raw_bytes") == len(bad.encode()))
    record("T12", "Invalid payload handled (malformed JSON, no 500, clean pass-through)",
           ok, {"status": st, "echoed_raw_bytes": d.get("body_raw_bytes") if d else None})


# ------------------------------------------------------------------ T13
def t13():
    """100 simple requests through Kong (baseline route)."""
    ok_count = 0
    failures = []
    for i in range(100):
        try:
            st, h, b = req("GET", f"{PROXY}/test-echo?i={i}", timeout=15)
            d = j(b)
            if st == 200 and isinstance(d, dict) and d.get("backend") == BACKEND:
                ok_count += 1
            else:
                failures.append({"i": i, "status": st})
        except Exception as e:  # noqa: BLE001
            failures.append({"i": i, "exc": repr(e)})
    ok = ok_count == 100
    record("T13", "100 simple requests through Kong — all 200 + valid body",
           ok, {"ok": ok_count, "failures": failures[:10]})


# ------------------------------------------------------------------ T14
def t14():
    """100 requests with plugins enabled (full chain on /combined-echo)."""
    ok_count = 0
    failures = []
    for i in range(100):
        try:
            st, h, b = req("POST", PROXY + "/combined-echo",
                           headers={"X-Api-Key": "t14",
                                    "X-Correlation-Id": f"t14-{i:03d}"},
                           data=json.dumps({"customer_id": i}), timeout=15)
            d = j(b)
            good = (
                st == 200 and isinstance(d, dict)
                and d.get("success") == "ok"
                and d.get("data", {}).get("received_customer_id") == i
                and d.get("data", {}).get("received_correlation_id") == f"t14-{i:03d}"
                and hdr(h, "X-Oss-Post") == "processed"
            )
            if good:
                ok_count += 1
            else:
                failures.append({"i": i, "status": st,
                                 "body": (d or {}).get("data")})
        except Exception as e:  # noqa: BLE001
            failures.append({"i": i, "exc": repr(e)})
    ok = ok_count == 100
    record("T14", "100 requests with plugins (combined pre+post chain) — all correct",
           ok, {"ok": ok_count, "failures": failures[:10]})


# ------------------------------------------------------------------ T15
def t15():
    """Latency statistics for the baseline route (100 fresh requests)."""
    samples = []
    for i in range(100):
        t0 = time.perf_counter()
        st, h, b = req("GET", f"{PROXY}/test-echo?lat={i}", timeout=15)
        ms = (time.perf_counter() - t0) * 1000.0
        if st != 200:
            record("T15", "Latency statistics", False,
                   {"abort": f"request {i} returned {st}"})
            return
        samples.append(ms)
    s = sorted(samples)
    stats = {"n": len(s),
             "mean_ms": round(statistics.fmean(s), 3),
             "p50_ms": round(statistics.median(s), 3),
             "p95_ms": round(pct(s, 95), 3),
             "p99_ms": round(pct(s, 99), 3),
             "min_ms": round(s[0], 3), "max_ms": round(s[-1], 3)}
    ok = stats["p95_ms"] < 1000.0
    record("T15", f"Latency: p50={stats['p50_ms']}ms p95={stats['p95_ms']}ms "
                  f"p99={stats['p99_ms']}ms (threshold p95 < 1000ms)",
           ok, stats)


# ------------------------------------------------------------------ T16
def t16():
    """Error rate: 200 mixed requests across healthy routes -> 0% errors."""
    errors = 0
    total = 0
    for i in range(100):
        try:
            st, _, _ = req("GET", f"{PROXY}/test-echo?e={i}", timeout=15)
            total += 1
            if st != 200:
                errors += 1
        except Exception:  # noqa: BLE001
            total += 1
            errors += 1
    for i in range(100):
        try:
            st, _, _ = req("POST", PROXY + "/secure-echo",
                           headers={"X-Api-Key": "t16"},
                           data=json.dumps({"i": i}), timeout=15)
            total += 1
            if st != 200:
                errors += 1
        except Exception:  # noqa: BLE001
            total += 1
            errors += 1
    rate = (100.0 * errors / total) if total else 100.0
    ok = errors == 0
    record("T16", f"Error rate over {total} mixed requests",
           ok, {"errors": errors, "total": total, "error_rate_pct": round(rate, 3)})


# ------------------------------------------------------------------ T17
def t17():
    """Restart / stability test (delegates to scripts/restart-test.sh)."""
    try:
        p = subprocess.run(["bash", RESTART_SCRIPT], capture_output=True,
                           text=True, timeout=600)
        ok = p.returncode == 0
        tail = (p.stdout or "").strip().splitlines()[-8:]
        detail = {"rc": p.returncode, "stdout_tail": tail}
        if p.returncode != 0:
            detail["stderr_tail"] = (p.stderr or "").strip().splitlines()[-8:]
        record("T17", "Restart/stability test (kong restart, 12-route fingerprint identical)",
               ok, detail)
    except subprocess.TimeoutExpired:
        record("T17", "Restart/stability test", False, {"error": "timeout 600s"})
    except Exception as e:  # noqa: BLE001
        record("T17", "Restart/stability test", False, {"error": repr(e)})


# ------------------------------------------------------------------ T18
def t18():
    """Admin API not exposed outside loopback."""
    rc, out = sh(
        "docker inspect --format '{{json .NetworkSettings.Ports}}' "
        "kong-gw-oss-kong 2>/dev/null")
    bad = []
    if rc != 0:
        bad.append("could not inspect kong container ports")
    else:
        ports = json.loads(out.strip() or "{}")
        for pub, binds in ports.items():
            for bnd in (binds or []):
                host_ip = bnd.get("HostIp") or "0.0.0.0"
                if host_ip != "127.0.0.1":
                    bad.append(f"port {pub}->{bnd.get('HostPort')} bound to {host_ip}")
    ok = not bad
    record("T18", "Admin/Proxy ports bound to loopback only (no external exposure)",
           ok, {"violations": bad,
                "note": "binding map from docker inspect of kong-gw-oss-kong"})


def main():
    started = datetime.now(timezone.utc).isoformat()
    for fn in (t01, t02, t03, t04, t05, t06, t07, t08, t09,
               t10, t11, t12, t13, t14, t15, t16, t17, t18):
        try:
            fn()
        except Exception as e:  # noqa: BLE001
            record(fn.__name__.upper(), fn.__doc__ or fn.__name__, False,
                   {"exception": repr(e)})

    passed = sum(1 for r in RESULTS_LIST if r["verdict"] == "PASS")
    failed = sum(1 for r in RESULTS_LIST if r["verdict"] == "FAIL")
    skipped = sum(1 for r in RESULTS_LIST if r["verdict"] == "SKIP")

    with open(os.path.join(RESULTS, "test-suite.json"), "w") as f:
        json.dump({"timestamp": started, "proxy": PROXY, "admin": ADMIN,
                   "backend": BACKEND, "cases": RESULTS_LIST}, f, indent=2)

    lines = [
        "Kong OSS release — Mandatory Test Suite Report (18 tests)",
        "=" * 72,
        f"timestamp (UTC): {started}",
        f"proxy: {PROXY}   admin: {ADMIN}   backend: {BACKEND}",
        f"cases: {len(RESULTS_LIST)}  PASS: {passed}  FAIL: {failed}  SKIP: {skipped}",
        "",
    ]
    for r in RESULTS_LIST:
        lines.append(f"[{r['verdict']}] {r['id']}  {r['desc']}")
        lines.append(f"      {json.dumps(r['detail'], default=str)[:300]}")
    lines.append("")
    lines.append(f"RESULT: {passed}/{len(RESULTS_LIST)} mandatory tests PASS"
                 + ("" if failed == 0 else f", {failed} FAIL"))
    report = "\n".join(lines) + "\n"
    with open(os.path.join(RESULTS, "test-suite-report.txt"), "w") as f:
        f.write(report)
    print()
    print(report)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
