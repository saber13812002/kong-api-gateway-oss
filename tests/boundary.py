#!/usr/bin/env python3
"""Kong OSS release — security boundary tests for the hardened plugins.

Companion to the mandatory suite. Talks only to the loopback proxy.
Writes:
  results/boundary-report.txt
  results/boundary.json

Cases:
  B1 valid JSON request below the 1 MiB limit   (transform applied)
  B2 request exceeding the configured limit      (pass-through, intact)
  B3 invalid JSON request                        (pass-through, no 500)
  B4 missing required header                     (400 JSON error)
  B5 valid response below the limit              (transform applied)
  B6 response exceeding the limit                (pass-through, intact)
  B7 empty response                              (200, 0 bytes, clean)
  B8 chunked response framing                    (Transfer-Encoding: chunked)
  B9 concurrent requests, distinct correlation ids

Usage:
  python3 tests/boundary.py [PROXY_URL] [BACKEND_NAME]

NOTE: these verify the *documented* boundary behavior of the plugins
(deterministic pass-through for over-budget bodies, streaming budget
enforcement, per-request state isolation). They do NOT prove resistance
to every DoS scenario; load/fuzz testing remains future work.
"""
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

BASE = os.environ.get("PROXY_URL", sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:18080")
BACKEND = os.environ.get("ECHO_BACKEND_NAME", sys.argv[2] if len(sys.argv) > 2 else "oss-echo")
HOSTPORT = BASE.split("://", 1)[1]

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")
os.makedirs(RESULTS, exist_ok=True)

LIMIT = 1024 * 1024  # default max_body_bytes

RESULTS_LIST = []


def req(method, path, headers=None, data=None, timeout=30):
    h = {"Host": HOSTPORT}
    h.update(headers or {})
    body = data.encode("utf-8") if isinstance(data, str) else (data or None)
    r = urllib.request.Request(BASE + path, data=body, method=method)
    for k, v in h.items():
        r.add_header(k, v)
    if body is not None and "Content-Type" not in h:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def hdr(h, name):
    for k, v in h.items():
        if k.lower() == name.lower():
            return v
    return None


def record(cid, desc, ok, detail):
    RESULTS_LIST.append({"id": cid, "desc": desc,
                         "verdict": "PASS" if ok else "FAIL",
                         "detail": detail})
    print(f"{'PASS' if ok else 'FAIL'}  {cid}  {desc}")
    if not ok:
        print(f"      detail: {json.dumps(detail, default=str)[:500]}")


# ---------------------------------------------------------------- B1
def b1():
    """Valid JSON request < 1 MiB on /t-pre -> body rename applied."""
    pad = "x" * 880_000  # ~880 KiB payload, well under the 1 MiB limit
    body = json.dumps({"customer_id": 777, "pad": pad})
    st, h, b = req("POST", "/t-pre",
                   {"X-Api-Key": "boundary"}, body)
    d = json.loads(b.decode())
    up_body = d.get("body")
    ok = (st == 200
          and isinstance(up_body, dict)
          and up_body.get("customerId") == 777
          and "customer_id" not in up_body
          and up_body.get("pad") == pad)
    record("B1", "valid JSON request <1MiB (880KiB) -> rename applied, body intact",
           ok, {"status": st, "len": len(b),
                "renamed": isinstance(up_body, dict) and up_body.get("customerId")})


# ---------------------------------------------------------------- B2
def b2():
    """Request > 1 MiB on /t-pre -> pass-through untransformed."""
    pad = "x" * 1_500_000  # ~1.5 MiB, over the limit
    body = json.dumps({"customer_id": 888, "pad": pad})
    assert len(body) > LIMIT
    st, h, b = req("POST", "/t-pre",
                   {"X-Api-Key": "boundary"}, body, timeout=60)
    d = json.loads(b.decode())
    up_body = d.get("body")
    # passthrough: echo received the ORIGINAL key, full pad intact
    ok = (st == 200
          and isinstance(up_body, dict)
          and up_body.get("customer_id") == 888
          and "customerId" not in up_body
          and up_body.get("pad") == pad)
    record("B2", f"request >1MiB ({len(body)} B) -> pass-through untransformed, intact",
           ok, {"status": st, "req_bytes": len(body), "resp_len": len(b),
                "still_original_key": isinstance(up_body, dict) and up_body.get("customer_id")})


# ---------------------------------------------------------------- B3
def b3():
    """Invalid JSON < 1 MiB -> pcall decode fails -> original body passes."""
    bad = '{"customer_id": 999, "broken": ' + "y" * 200_000 + " }"  # unterminated
    st, h, b = req("POST", "/t-pre", {"X-Api-Key": "boundary"}, bad)
    d = json.loads(b.decode())
    # echo could not parse it either -> returns the raw string
    ok = (st == 200
          and d.get("body") == bad
          and d.get("body_raw_bytes") == len(bad.encode()))
    record("B3", "invalid JSON <1MiB -> original body passed through, no 500",
           ok, {"status": st, "echoed_raw": d.get("body_raw_bytes")})


# ---------------------------------------------------------------- B4
def b4():
    """Missing required header X-Api-Key -> 400 JSON error (no leak)."""
    st, h, b = req("POST", "/t-pre", None, '{"a":1}')
    d = json.loads(b.decode())
    ok = (st == 400
          and d.get("error") == "missing_required_header"
          and d.get("plugin") == "oss-pre"
          and "X-Api-Key" in json.dumps(d))
    record("B4", "missing X-Api-Key -> 400 missing_required_header (oss-pre)",
           ok, {"status": st, "body": d})


# ---------------------------------------------------------------- B5
def b5():
    """Small JSON response -> rename status->success applied (under limit)."""
    st, h, b = req("GET", "/fixed-ok")
    d = json.loads(b.decode())
    ok = (st == 200
          and d.get("success") == "ok"
          and "status" not in d
          and d.get("data", {}).get("id") == 123
          and hdr(h, "X-Oss-Post") == "processed")
    record("B5", "valid response <1MiB -> transform applied (status->success)",
           ok, {"status": st, "body": d, "x_oss_post": hdr(h, "X-Oss-Post")})


# ---------------------------------------------------------------- B6
def b6():
    """Response > 1 MiB via echo of a 1.9 MiB POST body -> pass-through."""
    big = "z" * 1_990_000
    body = json.dumps({"data": big})
    st, h, b = req("POST", "/t-post", None, body, timeout=60)
    d = json.loads(b.decode())
    # over-budget: original response passes through UNtransformed:
    #  - "backend" NOT renamed to "gateway"
    #  - full 1.99 MiB pad intact (flush-before-drop guarantees completeness)
    ok = (st == 200
          and d.get("backend") == BACKEND
          and d.get("body", {}).get("data") == big
          and len(b) > LIMIT)
    record("B6", f"response >1MiB ({len(b)} B) -> pass-through untransformed, COMPLETE",
           ok, {"status": st, "resp_len": len(b),
                "untransformed_backend": d.get("backend"),
                "pad_intact": d.get("body", {}).get("data") == big})


# ---------------------------------------------------------------- B7
def b7():
    """Empty response -> 200, 0 bytes, header still added, no corruption."""
    st, h, b = req("GET", "/empty")
    ok = (st == 200 and len(b) == 0 and hdr(h, "X-Oss-Post") == "processed")
    record("B7", "empty response -> 200, 0 bytes, X-Oss-Post present",
           ok, {"status": st, "bytes": len(b), "x_oss_post": hdr(h, "X-Oss-Post")})


# ---------------------------------------------------------------- B8
def b8():
    """Transform routes are chunked (Content-Length cleared by the plugin)."""
    st, h, b = req("GET", "/fixed-ok")
    te = hdr(h, "Transfer-Encoding")
    cl = hdr(h, "Content-Length")
    ok = (st == 200 and te is not None and "chunked" in te.lower()
          and cl in (None, "0")
          and json.loads(b.decode()).get("success") == "ok")
    record("B8", "transform response is chunked (no Content-Length), body fine",
           ok, {"status": st, "transfer_encoding": te, "content_length": cl,
                "body": b.decode()[:80]})


# ---------------------------------------------------------------- B9
def b9():
    """10 concurrent requests -> 10 distinct correlation ids, no cross-talk."""
    N = 10
    out = {}
    lock = threading.Lock()

    def worker(i):
        body = json.dumps({"i": i, "tag": f"t{i:03d}"})
        st, h, b = req("POST", "/t-post", None, body, timeout=30)
        cid = hdr(h, "X-Correlation-Id")
        d = json.loads(b.decode())
        with lock:
            out[i] = {"st": st, "cid_header": cid,
                      "cid_in_echo": d.get("headers", {}).get("X-Correlation-Id"),
                      "tag": d.get("body", {}).get("tag")}

    ts = [threading.Thread(target=worker, args=(i,)) for i in range(N)]
    t0 = time.monotonic()
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    ms = (time.monotonic() - t0) * 1000

    cids = [out[i]["cid_header"] for i in range(N)]
    distinct = len(set(cids))
    all_prefixed = all(c and c.startswith("oss-") for c in cids)
    consistent = all(out[i]["cid_header"] == out[i]["cid_in_echo"] for i in range(N))
    all_ok_status = all(out[i]["st"] == 200 for i in range(N))
    tags_ok = all(out[i]["tag"] == f"t{i:03d}" for i in range(N))
    ok = (distinct == N and all_prefixed and consistent and all_ok_status and tags_ok)
    record("B9", f"10 concurrent requests: {distinct} distinct correlation ids, "
                 f"consistent, no cross-talk ({ms:.0f} ms total)",
           ok, {"distinct": distinct, "ms": round(ms, 1),
                "ids": [c[:24] + "..." for c in cids[:3]]})


def main():
    started = datetime.now(timezone.utc).isoformat()
    for fn in (b1, b2, b3, b4, b5, b6, b7, b8, b9):
        try:
            fn()
        except Exception as e:  # noqa: BLE001
            record(fn.__name__.upper(), fn.__doc__ or fn.__name__, False,
                   {"exception": repr(e)})

    passed = sum(1 for r in RESULTS_LIST if r["verdict"] == "PASS")
    failed = len(RESULTS_LIST) - passed
    with open(os.path.join(RESULTS, "boundary.json"), "w") as f:
        json.dump({"timestamp": started, "limit_bytes": LIMIT,
                   "cases": RESULTS_LIST}, f, indent=2)
    lines = [
        "Kong OSS release — Security Boundary Test Report (hardened plugins)",
        "=" * 72,
        f"timestamp (UTC): {started}",
        f"proxy: {BASE}   backend: {BACKEND}",
        f"max_body_bytes limit: {LIMIT} (default)",
        f"cases: {len(RESULTS_LIST)}  PASS: {passed}  FAIL: {failed}",
        "",
    ]
    for r in RESULTS_LIST:
        lines.append(f"[{r['verdict']}] {r['id']}  {r['desc']}")
        lines.append(f"      {json.dumps(r['detail'], default=str)[:300]}")
    lines.append("")
    lines.append("RESULT: "
                 f"{passed}/{len(RESULTS_LIST)} boundary cases PASS"
                 + ("" if failed == 0 else f", {failed} FAIL"))
    lines.append("scope note: verifies documented boundary behavior of the")
    lines.append("plugins; does NOT prove resistance to every DoS scenario.")
    report = "\n".join(lines) + "\n"
    with open(os.path.join(RESULTS, "boundary-report.txt"), "w") as f:
        f.write(report)
    print()
    print(report)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
