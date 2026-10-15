#!/usr/bin/env python3
"""Print per-round block stats from results.json (for the STEP 3 report)."""
import json
import statistics
import sys

d = json.load(open(sys.argv[1]))

def pct(s, p):
    s = sorted(s)
    k = max(1, min(len(s), int(round(p / 100.0 * len(s)))))
    return s[k - 1]

print("== SUMMARY ==")
print(json.dumps(d["summary"], indent=1))
print("\n== PER ROUND / BLOCK ==")
for r in d["rounds"]:
    for b in r["blocks"]:
        v = [s["latency_ms"] for s in b["samples"]]
        print(
            "R%d pos%d %-6s n=%d mean=%.3fms p50=%.3fms p95=%.3fms p99=%.3fms "
            "min=%.3f max=%.3f stdev=%.3f rps=%s ok=%d fail=%d"
            % (
                r["round"], b["order"], b["path"], len(v),
                statistics.fmean(v), statistics.median(v), pct(v, 95), pct(v, 99),
                min(v), max(v), statistics.stdev(v), b["rps"], b["successful"], b["failed"],
            )
        )
