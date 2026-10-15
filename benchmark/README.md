# STEP 3 — Kong OSS Baseline Performance Benchmark

Baseline latency comparison: **direct echo backend** vs **through Kong 3.9.4**,
100 measured requests per round × 3 rounds (300 per path), concurrency = 1.

## Results (2026-10-15, s52)

| Metric | Direct backend | Through Kong | Overhead |
|---|---|---|---|
| Requests (measured) | 300 | 300 | — |
| Success / fail | 300 / 0 | 300 / 0 | — |
| Mean latency | 0.739 ms | 1.145 ms | +0.406 ms (+54.9%) |
| Median (p50) | 0.711 ms | 1.071 ms | +0.360 ms (+50.6%) |
| p95 | 1.085 ms | 1.780 ms | +0.695 ms (+64.1%) |
| p99 | 1.708 ms | 2.067 ms | +0.359 ms (+21.0%) |
| Min | 0.474 ms | 0.687 ms | +0.213 ms |
| Max | 1.888 ms | 2.473 ms | +0.585 ms |
| Std dev | 0.211 ms | 0.304 ms | +0.093 ms |
| Throughput (measured window) | 1310.0 rps | 831.0 rps | — |
| Failure rate | 0.00% | 0.00% | — |

Per round (alternating order to reduce drift bias):

| Round | Order | direct mean | kong mean | kong−direct |
|---|---|---|---|---|
| 1 | direct → kong | 0.701 ms | 1.048 ms | +0.347 ms |
| 2 | kong → direct | 0.748 ms | 1.241 ms | +0.493 ms |
| 3 | direct → kong | 0.769 ms | 1.144 ms | +0.375 ms |

## Methodology

- **Client:** temp container `kong-gw-trial-bench-run` (image
  `kong-gw-trial-bench:1.0`, base `python:3.12.11-alpine3.21`, Python 3.12 stdlib
  `http.client`), running **on the internal Docker network `kong-gw-trial-net`**
  — no host ports exposed, client and targets on the same L2 segment for both
  paths (fair comparison).
- **Targets:** direct = `http://kong-gw-trial-echo:9000/` ; kong =
  `http://kong-gw-trial-kong:8000/test-echo` (Kong's internal proxy port, not
  the host loopback mapping).
- **Requests:** GET, fixed query `?payload=fixed-benchmark&n=3`, fixed headers
  (`User-Agent: kong-bench/1.0`, `X-Bench: step3-baseline`), concurrency 1,
  **fresh TCP+HTTP connection per request** (no keep-alive reuse).
- **Warm-up:** 20 requests per block excluded from measurement (cold-cache /
  first-request effects removed — e.g. the 61ms first-request proxy latency
  seen in STEP 2).
- **Validation:** every response checked for HTTP 200 + JSON body containing
  `backend=kong-gw-trial-echo` and `method=GET`. 600/600 valid.
- **Percentiles:** nearest-rank on sorted samples.
- **Overhead:** per-request latency difference (Kong − direct), never
  throughput-derived.
- **Settle:** 2 s pause between blocks.

## Environment at test time (before)

- Ubuntu 24.04.4 LTS, 10 cores, 23 GiB RAM (8.9 GiB available), swap full
  (4.0Gi used — noted in STEP 1.1), disk 87% used (75G free), load avg 2.50
- iostat at start: `%util` < 1% (no disk bottleneck), `%iowait` 0.00
- ulimits: host shell soft 1024 / hard 1048576; **Kong container raised to
  65535 via compose `ulimits.nofile`** (fixes the `ulimit 1024` warning); no
  system-wide change
- Kong stack baseline: kong 2.32% CPU / 641 MiB, db 38 MiB, echo 12 MiB
- 39 containers running before **and** after (no existing service touched)

## Files

| File | Content |
|---|---|
| `results.json` | Full results incl. **all 600 raw latency samples** per round/block |
| `results.csv` | Flat raw samples: `path,round,order,seq,status,valid_json,latency_ms` |
| `env.txt` | Environment snapshot (OS, CPU/RAM/disk/iostat/ulimits/stats baseline) |
| `meta.json` | Tool + config metadata (versions, counts, timestamps) |
| `run.sh` | Reproducible runner (executes on s52 from `~/kong-gateway`) |
| `precheck.sh` | Post-recreate health/ulimit/route pre-check |
| `summarize.py` | Prints per-round stats from `results.json` |
| `../bench/bench.py` | Benchmark client (in-container) |
| `../bench/Dockerfile` | Pinned client image build |

## Reproduce

```bash
# on s52
bash ~/kong-gateway/benchmark/run.sh
python3 ~/kong-gateway/benchmark/summarize.py ~/kong-gateway/benchmark/results/results.json
```

## Caveats

- Shared server (39 other containers); figures are for **relative** Kong
  overhead comparison, not production capacity.
- Concurrency = 1 → baseline single-request latency only; 100-RPS capacity
  testing is a separate future step.
- Internal Docker network (same L2 for both paths) — does not include host
  loopback NAT overhead of `127.0.0.1:18080`.
- Swap fully used on the host (pre-existing condition from STEP 1.1) — no swap
  activity observed during the 13 s test window (iowait 0.00).
