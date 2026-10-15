#!/usr/bin/env python3
"""STEP 4 — functional test driver for all 7 transformation scenarios.

Runs on the s52 host (python3, stdlib only) against the loopback proxy
http://127.0.0.1:18080. Writes:
  results/step4-results.json   (machine-readable, every case raw data)
  results/step4-report.txt     (human-readable per-scenario report)
  results/raw/<case-id>.txt    (raw request/response dumps per case)

Exit code 0 iff every case PASSes.
"""
import json
import os
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone

BASE = "http://127.0.0.1:18080"
ADMIN = "http://127.0.0.1:18001"
HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")
RAW = os.path.join(RESULTS, "raw")
os.makedirs(RAW, exist_ok=True)

CASES = []  # filled below


def case(cid, scenario, desc):
    def deco(fn):
        CASES.append((cid, scenario, desc, fn))
        return fn
    return deco


# ---------------------------------------------------------------- helpers

def req(method, path, headers=None, data=None):
    """Do one request; return (status, resp_headers, body_bytes)."""
    h = {"Host": "127.0.0.1:18080"}
    h.update(headers or {})
    body = data.encode("utf-8") if isinstance(data, str) else (data or None)
    r = urllib.request.Request(BASE + path, data=body, method=method)
    for k, v in h.items():
        r.add_header(k, v)
    if body is not None and "Content-Type" not in h:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=15) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def j(body):
    try:
        return json.loads(body.decode("utf-8"))
    except Exception:
        return None


def hdr(resp_h, name):
    for k, v in resp_h.items():
        if k.lower() == name.lower():
            return v
    return None


# ---------------------------------------------------------------- scenarios

@case("B0-1", "0-baseline", "GET /test-echo?name=kong still works (integrity)")
def b0_1():
    st, h, b = req("GET", "/test-echo?name=kong")
    d = j(b)
    assert st == 200, f"status {st}"
    assert d and d["query"]["name"] == "kong", d
    assert d["backend"] == "kong-gw-trial-echo", d
    assert hdr(h, "X-Step4-Post") is None, "unexpected X-Step4-Post on baseline"
    assert hdr(h, "X-Gateway-Processed") is None, "unexpected X-Gateway-Processed on baseline"
    return {"upstream_saw": "query.name=kong (echo passthrough)",
            "upstream_response": d}


@case("B0-2", "0-baseline", "POST /test-echo body unchanged (integrity)")
def b0_2():
    st, h, b = req("POST", "/test-echo", {"X-Test-Header": "kong-test-123"},
                   '{"name":"Kong","project":"Organization API Gateway","test":2}')
    d = j(b)
    assert st == 200, f"status {st}"
    assert d and d["body"] == {"name": "Kong", "project": "Organization API Gateway", "test": 2}, d
    assert d["headers"].get("X-Test-Header") == "kong-test-123", d
    return {"upstream_saw": "unchanged body + X-Test-Header passthrough",
            "upstream_response": d}


@case("S1-1", "1-req-header", "X-Client-Type: legacy -> modern on upstream (request-transformer replace)")
def s1_1():
    st, h, b = req("GET", "/t-req-header", {"X-Client-Type": "legacy"})
    d = j(b)
    assert st == 200, f"status {st}"
    seen = (d or {}).get("headers", {}).get("X-Client-Type")
    assert seen == "modern", f"upstream saw {seen!r}"
    assert d["backend"] == "kong-gw-trial-echo"
    return {"upstream_saw": {"X-Client-Type": seen},
            "upstream_response": d,
            "client_body": d}


@case("S1-2", "1-req-header", "control: baseline /test-echo leaves X-Client-Type untouched")
def s1_2():
    st, h, b = req("GET", "/test-echo", {"X-Client-Type": "legacy"})
    d = j(b)
    assert st == 200, f"status {st}"
    seen = (d or {}).get("headers", {}).get("X-Client-Type")
    assert seen == "legacy", f"baseline route modified header: {seen!r}"
    return {"upstream_saw": {"X-Client-Type": seen}, "upstream_response": d}


@case("S2-1", "2-req-json", "POST body customer_id -> customerId (request-transformer replace body)")
def s2_1():
    st, h, b = req("POST", "/t-req-json", None,
                   '{"customer_id":123,"name":"Ali"}')
    d = j(b)
    assert st == 200, f"status {st}"
    up_body = (d or {}).get("body")
    assert up_body == {"customerId": 123, "name": "Ali"}, up_body
    assert "customer_id" not in up_body, up_body
    return {"upstream_saw": up_body, "upstream_response": d, "client_body": d}


@case("S2-2", "2-req-json", "control: baseline /test-echo leaves body untouched")
def s2_2():
    st, h, b = req("POST", "/test-echo", None,
                   '{"customer_id":123,"name":"Ali"}')
    d = j(b)
    assert st == 200, f"status {st}"
    up_body = (d or {}).get("body")
    assert up_body == {"customer_id": 123, "name": "Ali"}, up_body
    return {"upstream_saw": up_body, "upstream_response": d}


@case("S3-1", "3-resp-header", "client receives X-Gateway-Processed: kong (response-transformer add)")
def s3_1():
    st, h, b = req("GET", "/t-resp-header")
    d = j(b)
    assert st == 200, f"status {st}"
    v = hdr(h, "X-Gateway-Processed")
    assert v == "kong", f"X-Gateway-Processed={v!r}"
    assert d and d["backend"] == "kong-gw-trial-echo"
    return {"client_headers": {"X-Gateway-Processed": v}, "client_body": d}


@case("S3-2", "3-resp-header", "control: baseline /test-echo has no X-Gateway-Processed")
def s3_2():
    st, h, b = req("GET", "/test-echo")
    v = hdr(h, "X-Gateway-Processed")
    assert v is None, f"baseline route carries X-Gateway-Processed={v!r}"
    return {"client_headers": {}}


@case("S4-1", "4-resp-json", "upstream {'status':'ok','data':{'id':123}} -> client {'success':'ok','data':{'id':123}} (step4-post body transform)")
def s4_1():
    st, h, b = req("GET", "/fixed-ok")
    d = j(b)
    assert st == 200, f"status {st}"
    assert d == {"success": "ok", "data": {"id": 123}}, f"body={d!r}"
    assert "status" not in d, "old key still present"
    assert (hdr(h, "Content-Type") or "").startswith("application/json"), hdr(h, "Content-Type")
    assert hdr(h, "X-Step4-Post") == "processed"
    # transform routes force chunked client framing (Content-Length cleared
    # in ACCESS phase) — the original 35-byte upstream body became 45 bytes
    te = hdr(h, "Transfer-Encoding")
    assert te == "chunked", f"Transfer-Encoding={te!r} (expected chunked)"
    assert hdr(h, "Content-Length") is None, "Content-Length must be absent (chunked)"
    return {"upstream_body": {"status": "ok", "data": {"id": 123}},
            "client_body": d,
            "transfer_encoding": te,
            "body_bytes": len(b)}


@case("S4-2", "4-resp-json", "edge: empty upstream body passes through (200, zero-length, chunked)")
def s4_2():
    st, h, b = req("GET", "/empty")
    assert st == 200, f"status {st}"
    assert b == b"", f"body={b!r}"
    assert hdr(h, "X-Step4-Post") == "processed"
    assert hdr(h, "Transfer-Encoding") == "chunked"
    return {"upstream_body": b"", "client_bytes": 0,
            "transfer_encoding": hdr(h, "Transfer-Encoding")}


@case("S4-3", "4-resp-json", "edge: non-JSON upstream body passes through untouched")
def s4_3():
    st, h, b = req("GET", "/not-json")
    assert st == 200, f"status {st}"
    assert b == b"this is not json", b
    assert (hdr(h, "Content-Type") or "").startswith("text/plain")
    assert hdr(h, "X-Step4-Post") == "processed"
    return {"upstream_body": b"this is not json", "client_body": b.decode()}


@case("S4-4", "4-resp-json", "edge: upstream 500 error body passes through untouched")
def s4_4():
    st, h, b = req("GET", "/echo-error")
    d = j(b)
    assert st == 500, f"status {st}"
    assert d == {"status": "error", "detail": "simulated upstream failure"}, d
    assert hdr(h, "X-Step4-Post") == "processed"
    return {"upstream_status": 500, "upstream_body": d, "client_body": d}


@case("S5-1", "5-custom-pre", "required header + existing correlation id preserved + body rename (step4-pre)")
def s5_1():
    st, h, b = req("POST", "/t-custom-pre",
                   {"X-Api-Key": "test-key-1", "X-Correlation-Id": "cli-corr-77"},
                   '{"customer_id":123,"name":"Ali"}')
    d = j(b)
    assert st == 200, f"status {st}"
    up = d or {}
    assert up["body"] == {"customerId": 123, "name": "Ali"}, up["body"]
    assert up["headers"].get("X-Correlation-Id") == "cli-corr-77", up["headers"]
    assert up["headers"].get("X-Api-Key") == "test-key-1"
    return {"upstream_saw": {"body": up["body"],
                             "X-Correlation-Id": "cli-corr-77 (preserved)",
                             "X-Api-Key": "test-key-1"},
            "client_body": d}


@case("S5-2", "5-custom-pre", "missing X-Api-Key -> 400 controlled JSON error, body not forwarded")
def s5_2():
    st, h, b = req("POST", "/t-custom-pre",
                   {"X-Correlation-Id": "gen-check"}, '{"x":1}')
    d = j(b)
    assert st == 400, f"status {st}"
    assert d == {"error": "missing_required_header",
                 "header": "X-Api-Key", "plugin": "step4-pre"}, d
    return {"client_status": 400, "client_body": d}


@case("S5-3", "5-custom-pre", "correlation id generated when missing; non-renamed body preserved")
def s5_3():
    st, h, b = req("POST", "/t-custom-pre", {"X-Api-Key": "k2"}, '{"a":"b"}')
    d = j(b)
    assert st == 200, f"status {st}"
    up = d or {}
    cid = up["headers"].get("X-Correlation-Id")
    assert cid and cid.startswith("step4-"), f"X-Correlation-Id={cid!r}"
    assert up["body"] == {"a": "b"}, up["body"]
    return {"upstream_saw": {"X-Correlation-Id": cid, "body": up["body"]},
            "client_body": d}


@case("S5-4", "5-custom-pre", "GET without required header also rejected (400)")
def s5_4():
    st, h, b = req("GET", "/t-custom-pre")
    d = j(b)
    assert st == 400, f"status {st}"
    assert d and d.get("error") == "missing_required_header", d
    return {"client_status": 400, "client_body": d}


@case("S6-1", "6-custom-post", "response header + correlation echo + body rename backend->gateway (step4-pre+step4-post)")
def s6_1():
    st, h, b = req("GET", "/t-custom-post")
    d = j(b)
    assert st == 200, f"status {st}"
    assert d.get("gateway") == "kong-gw-trial-echo", d
    assert "backend" not in d, "old key still present"
    assert hdr(h, "X-Step4-Post") == "processed"
    cid = hdr(h, "X-Correlation-Id")
    assert cid and cid.startswith("step4-"), f"X-Correlation-Id={cid!r}"
    return {"client_body": d,
            "client_headers": {"X-Step4-Post": "processed",
                               "X-Correlation-Id": cid}}


@case("S6-2", "6-custom-post", "incoming X-Correlation-Id echoed back, not regenerated")
def s6_2():
    st, h, b = req("GET", "/t-custom-post", {"X-Correlation-Id": "pinned-corr-5"})
    assert st == 200, f"status {st}"
    cid = hdr(h, "X-Correlation-Id")
    assert cid == "pinned-corr-5", f"X-Correlation-Id={cid!r}"
    return {"client_headers": {"X-Correlation-Id": cid}}


@case("S6-3", "6-custom-post", "POST body passes through to upstream untouched; response still transformed")
def s6_3():
    st, h, b = req("POST", "/t-custom-post", None, '{"keep":"me"}')
    d = j(b)
    assert st == 200, f"status {st}"
    assert d.get("body") == {"keep": "me"}, d.get("body")
    assert d.get("gateway") == "kong-gw-trial-echo", d
    assert "backend" not in d
    return {"upstream_saw": {"body": {"keep": "me"}}, "client_body": d}


@case("S7-1", "7-combined", "full chain: required header OK + pinned correlation + req rename + resp rename + resp headers")
def s7_1():
    st, h, b = req("POST", "/combined-echo",
                   {"X-Api-Key": "final", "X-Correlation-Id": "corr-final-1"},
                   '{"customer_id":123,"name":"Ali"}')
    d = j(b)
    assert st == 200, f"status {st}"
    assert d == {"success": "ok",
                 "data": {"id": 123, "received_customer_id": 123,
                           "received_correlation_id": "corr-final-1"}}, d
    assert hdr(h, "X-Step4-Post") == "processed"
    assert hdr(h, "X-Correlation-Id") == "corr-final-1"
    return {"upstream_saw": {"body": {"customerId": 123, "name": "Ali"},
                             "X-Correlation-Id": "corr-final-1",
                             "X-Api-Key": "final"},
            "upstream_response": {"status": "ok", "data": {"id": 123,
                             "received_customer_id": 123,
                             "received_correlation_id": "corr-final-1"}},
            "client_body": d,
            "client_headers": {"X-Step4-Post": "processed",
                               "X-Correlation-Id": "corr-final-1"}}


@case("S7-2", "7-combined", "generated correlation id flows: request->upstream->response->client (single value)")
def s7_2():
    st, h, b = req("POST", "/combined-echo", {"X-Api-Key": "final"},
                   '{"customer_id":456,"name":"Reyhaneh"}')
    d = j(b)
    assert st == 200, f"status {st}"
    data = (d or {}).get("data") or {}
    cid_body = data.get("received_correlation_id")
    cid_hdr = hdr(h, "X-Correlation-Id")
    assert cid_body and cid_body.startswith("step4-"), cid_body
    assert cid_hdr == cid_body, f"header={cid_hdr!r} body={cid_body!r}"
    assert data.get("received_customer_id") == 456, data
    return {"upstream_saw": {"customerId": 456, "X-Correlation-Id": cid_body},
            "client_body": d,
            "client_headers": {"X-Correlation-Id": cid_hdr}}


@case("S7-3", "7-combined", "combined route without X-Api-Key -> 400 JSON error")
def s7_3():
    st, h, b = req("POST", "/combined-echo", None,
                   '{"customer_id":1,"name":"x"}')
    d = j(b)
    assert st == 400, f"status {st}"
    assert d and d.get("error") == "missing_required_header", d
    return {"client_status": 400, "client_body": d}


# ---------------------------------------------------------------- runner

def main():
    started = datetime.now(timezone.utc).isoformat()
    # snapshot baseline route state for the integrity comparison
    with urllib.request.urlopen(ADMIN + "/routes?size=100", timeout=10) as r:
        routes_now = json.load(r)
    baseline = [x for x in routes_now["data"] if x.get("paths") == ["/test-echo"]]
    routes_before = routes_now["total"]

    results = []
    for cid, scenario, desc, fn in CASES:
        t0 = time.monotonic()
        rec = {"id": cid, "scenario": scenario, "description": desc}
        try:
            detail = fn()
            ms = (time.monotonic() - t0) * 1000
            rec.update({"verdict": "PASS", "ms": round(ms, 2),
                        "observed": detail})
            print(f"PASS  {cid:6} {desc}")
        except AssertionError as e:
            ms = (time.monotonic() - t0) * 1000
            rec.update({"verdict": "FAIL", "ms": round(ms, 2),
                        "error": str(e)})
            print(f"FAIL  {cid:6} {desc}  -> {e}")
        except Exception as e:  # noqa: BLE001
            ms = (time.monotonic() - t0) * 1000
            rec.update({"verdict": "FAIL", "ms": round(ms, 2),
                        "error": repr(e)})
            print(f"FAIL  {cid:6} {desc}  -> {e!r}")
        results.append(rec)
        with open(os.path.join(RAW, cid + ".json"), "w") as f:
            json.dump(rec, f, indent=2, default=str)

    # baseline integrity after all traffic
    with urllib.request.urlopen(ADMIN + "/routes?size=100", timeout=10) as r:
        routes_after = json.load(r)
    baseline_after = [x for x in routes_after["data"]
                      if x.get("paths") == ["/test-echo"]]
    baseline_unchanged = bool(baseline) and baseline == baseline_after
    routes_total_after = routes_after["total"]

    passed = sum(1 for r in results if r["verdict"] == "PASS")
    failed = len(results) - passed
    summary = {
        "timestamp": started,
        "kong_version": None,
        "cases_total": len(results),
        "cases_pass": passed,
        "cases_fail": failed,
        "baseline_route_unchanged": baseline_unchanged,
        "routes_total_before": routes_before,
        "routes_total_after": routes_total_after,
    }
    try:
        with urllib.request.urlopen(ADMIN + "/", timeout=10) as r:
            summary["kong_version"] = json.load(r)["version"]
    except Exception:
        pass
    with open(os.path.join(RESULTS, "step4-results.json"), "w") as f:
        json.dump({"summary": summary, "cases": results}, f, indent=2)

    # human-readable report
    lines = [
        "STEP 4 — Kong OSS Pre/Post Transformation — Functional Test Report",
        "=" * 72,
        f"timestamp (UTC): {started}",
        f"kong version: {summary['kong_version']}",
        f"cases: {len(results)}  PASS: {passed}  FAIL: {failed}",
        f"baseline /test-echo route object unchanged: {baseline_unchanged}",
        f"routes total before={routes_before} after={routes_total_after}",
        "",
    ]
    cur = None
    for rec in results:
        if rec["scenario"] != cur:
            cur = rec["scenario"]
            lines += ["", "-" * 72, f"scenario: {cur}", "-" * 72]
        lines.append(f"[{rec['verdict']}] {rec['id']}  {rec['description']}")
        if rec["verdict"] == "PASS":
            obs = rec.get("observed") or {}
            for k in ("upstream_saw", "upstream_response", "upstream_body",
                      "upstream_status", "client_body", "client_headers",
                      "client_status", "client_bytes", "content_length",
                      "body_bytes"):
                if k in obs:
                    lines.append(f"    {k}: {json.dumps(obs[k], default=str)}")
        else:
            lines.append(f"    ERROR: {rec.get('error')}")
    report = "\n".join(lines) + "\n"
    with open(os.path.join(RESULTS, "step4-report.txt"), "w") as f:
        f.write(report)

    print()
    print(f"RESULT: {passed}/{len(results)} PASS, {failed} FAIL "
          f"(baseline unchanged: {baseline_unchanged})")
    print(f"report: {os.path.join(RESULTS, 'step4-report.txt')}")
    sys.exit(0 if failed == 0 and baseline_unchanged else 1)


if __name__ == "__main__":
    main()
