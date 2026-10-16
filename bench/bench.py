#!/usr/bin/env python3
"""Latency/throughput benchmark client (concurrency = 1 by default).

Methodology:
- One fresh TCP+HTTP connection per request (no client-side keep-alive).
- Per block: N warm-up requests are performed and EXCLUDED from
  measurement, then exactly M measured requests; every request is
  validated (HTTP 200 + parseable JSON with the expected backend marker).
- R rounds, alternating target order per round to reduce drift bias.
- Raw per-request latency samples are exported (JSON + CSV).

Percentiles: nearest-rank on sorted samples.

Environment (all optional, defaults in brackets):
  BENCH_DIRECT_HOST   [kong-gw-oss-echo]  direct-to-backend target host
  BENCH_DIRECT_PORT   [9000]
  BENCH_KONG_HOST     [kong-gw-oss-kong]  proxy target host
  BENCH_KONG_PORT     [8000]
  BENCH_BACKEND_NAME  [oss-echo]          expected "backend" JSON marker
  BENCH_N             [100]  measured requests per block
  BENCH_WARMUP        [20]   warm-up requests per block (excluded)
  BENCH_ROUNDS        [3]    rounds
  BENCH_CONCURRENCY   [1]    parallel workers per block (1 = sequential)

Usage: python bench.py <out_results.json> <out_raw.csv>
"""
import csv
import http.client
import json
import os
import statistics
import sys
import threading
import time
from datetime import datetime, timezone

TARGETS = {
    "direct": {
        "host": os.environ.get("BENCH_DIRECT_HOST", "kong-gw-oss-echo"),
        "port": int(os.environ.get("BENCH_DIRECT_PORT", "9000")),
        "path": "/",
    },
    "kong": {
        "host": os.environ.get("BENCH_KONG_HOST", "kong-gw-oss-kong"),
        "port": int(os.environ.get("BENCH_KONG_PORT", "8000")),
        "path": "/test-echo",
    },
}
BACKEND_NAME = os.environ.get("BENCH_BACKEND_NAME", "oss-echo")
QUERY = "?payload=fixed-benchmark&n=3"
HEADERS = {
    "User-Agent": "kong-bench/1.0",
    "X-Bench": "oss-release-baseline",
    "Accept": "application/json",
}
N = int(os.environ.get("BENCH_N", "100"))           # measured per block
WARMUP = int(os.environ.get("BENCH_WARMUP", "20"))  # excluded per block
ROUNDS = int(os.environ.get("BENCH_ROUNDS", "3"))
CONCURRENCY = int(os.environ.get("BENCH_CONCURRENCY", "1"))
PAUSE_S = 2.0                                       # settle between blocks
ROUND_ORDER = [
    ["direct", "kong"],
    ["kong", "direct"],
    ["direct", "kong"],
]


def do_request(host, port, path):
    conn = http.client.HTTPConnection(host, port, timeout=10)
    r = None
    t0 = time.perf_counter()
    try:
        conn.request("GET", path + QUERY, headers=HEADERS)
        r = conn.getresponse()
        body = r.read()
    finally:
        t1 = time.perf_counter()
        try:
            conn.close()
        except Exception:
            pass
    status = getattr(r, "status", 0)
    valid_json = False
    if status == 200:
        try:
            d = json.loads(body)
            valid_json = (
                isinstance(d, dict)
                and d.get("backend") == BACKEND_NAME
                and d.get("method") == "GET"
            )
        except Exception:
            valid_json = False
    return status, valid_json, (t1 - t0) * 1000.0


def run_block(path_name):
    t = TARGETS[path_name]
    # Adaptive warm-up: at least WARMUP requests, then continue until the
    # last 5 warmup requests are all fast (< 100 ms). After a Kong restart,
    # each of its ~4 workers needs its own cache/DNS warm-up and a fixed
    # warmup count can leave workers cold (observed 8 s first-request
    # latency leaking into the measured region).
    warm = []
    i = 0
    cap = max(WARMUP * 10, WARMUP + 200)
    while i < cap:
        i += 1
        _, _, ms = do_request(t["host"], t["port"], t["path"])
        warm.append(ms)
        if len(warm) >= 5 and i >= WARMUP and all(x < 100 for x in warm[-5:]):
            break
    samples = []
    lock = threading.Lock()
    counter = {"i": 0}
    c_lock = threading.Lock()

    def worker():
        while True:
            with c_lock:
                counter["i"] += 1
                if counter["i"] > N:
                    return
                seq = counter["i"]
            status, valid, ms = do_request(t["host"], t["port"], t["path"])
            rec = {"seq": seq, "status": status, "valid_json": valid,
                   "latency_ms": round(ms, 3)}
            with lock:
                samples.append(rec)

    t_start = time.perf_counter()
    if CONCURRENCY <= 1:
        for _ in range(N):
            status, valid, ms = do_request(t["host"], t["port"], t["path"])
            samples.append({"seq": len(samples) + 1, "status": status,
                            "valid_json": valid, "latency_ms": round(ms, 3)})
    else:
        threads = [threading.Thread(target=worker)
                   for _ in range(CONCURRENCY)]
        for th in threads:
            th.start()
        for th in threads:
            th.join()
    total_s = time.perf_counter() - t_start
    samples.sort(key=lambda s: s["seq"])
    return samples, total_s


def pct(sorted_vals, p):
    """Nearest-rank percentile: value at rank ceil(p/100 * n)."""
    if not sorted_vals:
        return None
    k = max(1, min(len(sorted_vals), int(round(p / 100.0 * len(sorted_vals)))))
    return sorted_vals[k - 1]


def summarize(per_path_samples):
    out = {}
    for path, vals in per_path_samples.items():
        s = sorted(vals)
        out[path] = {
            "total_requests": len(s),
            "mean_ms": round(statistics.fmean(s), 3),
            "median_ms": round(statistics.median(s), 3),
            "p95_ms": round(pct(s, 95), 3),
            "p99_ms": round(pct(s, 99), 3),
            "min_ms": round(s[0], 3),
            "max_ms": round(s[-1], 3),
            "stdev_ms": round(statistics.stdev(s), 3) if len(s) > 1 else 0.0,
        }
    d, k = out["direct"], out["kong"]
    out["overhead_ms"] = {
        "mean": round(k["mean_ms"] - d["mean_ms"], 3),
        "median": round(k["median_ms"] - d["median_ms"], 3),
        "p95": round(k["p95_ms"] - d["p95_ms"], 3),
        "p99": round(k["p99_ms"] - d["p99_ms"], 3),
    }
    out["overhead_pct"] = {
        "mean": round(100.0 * (k["mean_ms"] - d["mean_ms"]) / d["mean_ms"], 2),
        "median": round(100.0 * (k["median_ms"] - d["median_ms"]) / d["median_ms"], 2),
        "p95": round(100.0 * (k["p95_ms"] - d["p95_ms"]) / d["p95_ms"], 2),
        "p99": round(100.0 * (k["p99_ms"] - d["p99_ms"]) / d["p99_ms"], 2),
    }
    return out


def main():
    out_json, out_csv = sys.argv[1], sys.argv[2]
    meta = {}
    meta_path = os.path.join(os.path.dirname(os.path.abspath(out_json)), "meta.json")
    if os.path.exists(meta_path):
        try:
            with open(meta_path) as f:
                meta = json.load(f)
        except Exception:
            meta = {}

    results = {
        "tool": "kong-bench/1.0 (Python stdlib http.client, one fresh connection per request)",
        "python_version": sys.version.split()[0],
        "config": {
            "n_measured_per_block": N,
            "warmup_excluded_per_block": WARMUP,
            "rounds": ROUNDS,
            "concurrency": CONCURRENCY,
            "connection_reuse": False,
            "fixed_query": QUERY,
            "fixed_headers": HEADERS,
            "round_order": ROUND_ORDER,
            "targets": TARGETS,
            "backend_marker": BACKEND_NAME,
            "percentile_method": "nearest-rank on sorted samples",
            "pause_between_blocks_s": PAUSE_S,
            "measured_total_per_path": N * ROUNDS,
        },
        "started_at": datetime.now(timezone.utc).isoformat(),
        "host_metadata": meta,
        "rounds": [],
        "raw_csv": os.path.basename(out_csv),
    }

    all_samples = {"direct": [], "kong": []}
    csv_rows = []
    for r in range(1, ROUNDS + 1):
        order = ROUND_ORDER[(r - 1) % len(ROUND_ORDER)]
        round_rec = {"round": r, "blocks": []}
        for position, path_name in enumerate(order, start=1):
            samples, total_s = run_block(path_name)
            ok = sum(1 for s in samples if s["status"] == 200 and s["valid_json"])
            round_rec["blocks"].append(
                {
                    "path": path_name,
                    "order": position,
                    "measured_requests": len(samples),
                    "successful": ok,
                    "failed": len(samples) - ok,
                    "total_measured_s": round(total_s, 3),
                    "rps": round(len(samples) / total_s, 3) if total_s else None,
                    "samples": samples,
                }
            )
            all_samples[path_name].extend(s["latency_ms"] for s in samples)
            for s in samples:
                csv_rows.append(
                    [path_name, r, position, s["seq"], s["status"], int(s["valid_json"]), s["latency_ms"]]
                )
            time.sleep(PAUSE_S)
        results["rounds"].append(round_rec)

    results["finished_at"] = datetime.now(timezone.utc).isoformat()
    results["summary"] = summarize(all_samples)

    for path in ("direct", "kong"):
        tot = sum(
            b["total_measured_s"]
            for rd in results["rounds"]
            for b in rd["blocks"]
            if b["path"] == path
        )
        n = sum(
            b["measured_requests"]
            for rd in results["rounds"]
            for b in rd["blocks"]
            if b["path"] == path
        )
        ok = sum(
            b["successful"]
            for rd in results["rounds"]
            for b in rd["blocks"]
            if b["path"] == path
        )
        results["summary"][path].update(
            {
                "successful": ok,
                "failed": n - ok,
                "total_measured_s": round(tot, 3),
                "rps": round(n / tot, 3) if tot else None,
                "failure_rate_pct": round(100.0 * (n - ok) / n, 2) if n else 0.0,
            }
        )

    with open(out_json, "w") as f:
        json.dump(results, f, indent=2)
    with open(out_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["path", "round", "order", "seq", "status", "valid_json", "latency_ms"])
        w.writerows(csv_rows)

    s = results["summary"]
    print("BENCH_DONE")
    print(
        "direct: n={} mean={}ms p50={}ms p95={}ms p99={}ms rps={} fail={}".format(
            s["direct"]["total_requests"], s["direct"]["mean_ms"], s["direct"]["median_ms"],
            s["direct"]["p95_ms"], s["direct"]["p99_ms"], s["direct"]["rps"], s["direct"]["failed"],
        )
    )
    print(
        "kong:   n={} mean={}ms p50={}ms p95={}ms p99={}ms rps={} fail={}".format(
            s["kong"]["total_requests"], s["kong"]["mean_ms"], s["kong"]["median_ms"],
            s["kong"]["p95_ms"], s["kong"]["p99_ms"], s["kong"]["rps"], s["kong"]["failed"],
        )
    )
    print(
        "overhead mean: {}ms ({})% | p95: {}ms ({})%".format(
            s["overhead_ms"]["mean"], s["overhead_pct"]["mean"],
            s["overhead_ms"]["p95"], s["overhead_pct"]["p95"],
        )
    )


if __name__ == "__main__":
    main()
