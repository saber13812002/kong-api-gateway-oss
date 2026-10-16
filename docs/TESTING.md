# Testing Guide

## Test layers

| Script | What it does | Duration |
|---|---|---|
| `scripts/smoke-test.sh` | 14 fast end-to-end checks (containers, health, auth, transforms) | seconds |
| `tests/test_suite.py` | **18 mandatory tests** (T01–T18) | ~1–2 min |
| `tests/boundary.py` | **9 security boundary cases** (B1–B9) | ~1 min |
| `scripts/restart-test.sh` | kong restart + 12-route fingerprint comparison | ~1 min |
| `scripts/security-test.sh` | 11 posture checks (port bindings, isolation, .env, ro mounts, no published backend ports) | seconds |
| `scripts/benchmark.sh` | direct-vs-Kong latency/throughput (3 rounds × 100 measured) | ~1–3 min |
| `scripts/run-tests.sh` | suite + boundary together | ~2–3 min |

Run everything:

```bash
bash scripts/setup.sh          # install + configure
bash scripts/run-tests.sh      # 18 + 9
bash scripts/security-test.sh
bash scripts/benchmark.sh
```

## The 18 mandatory tests

| ID | Test | Method |
|---|---|---|
| T01 | PostgreSQL + Kong + Echo up and healthy | `docker inspect` state + health |
| T02 | Kong health check | Admin `GET /status` (`database.reachable == true`) + Admin `GET /` version + proxy `GET /test-echo` 200 |
| T03 | Service + Route creation verified | Admin API: all 10 services, 12 routes present |
| T04 | Direct Echo request (no Kong) | `docker exec … wget /health` |
| T05 | Echo via Kong (baseline) | `GET /test-echo?name=via-kong` |
| T06 | oss-pre function | `POST /t-pre` → rename + generated `oss-…` correlation id |
| T07 | oss-post function | `/fixed-ok` rename + `X-Oss-Post` + chunked; `/t-post` `backend`→`gateway` + correlation echo |
| T08 | Request header change | `X-Client-Type: legacy` → upstream sees `modern`; control route untouched |
| T09 | Request JSON field change | `request-transformer` remove + `add.body` (`"key:value"` pairs, no space after colon); control route untouched |
| T10 | Authentication (valid) | `POST /secure-echo` with `X-Api-Key` → 200 |
| T11 | Unauthorized rejected | without key → 400 `missing_required_header` (controlled JSON) |
| T12 | Invalid payload | malformed 5 KB JSON → 200 pass-through, no 500 |
| T13 | 100 simple requests | 100 × `GET /test-echo`, all 200 + valid backend marker |
| T14 | 100 requests with plugins | 100 × full pre+post chain on `/combined-echo`, all correct |
| T15 | Latency statistics | 100 fresh requests → p50/p95/p99 (p95 < 1000 ms gate) |
| T16 | Error rate | 200 mixed requests across healthy routes → 0 % errors |
| T17 | Restart / stability | `docker compose restart kong`, 12-route fingerprint identical, config survived |
| T18 | Admin API non-exposure | `docker inspect` port bindings: loopback only |

## Boundary cases (B1–B9)

| ID | Case | Expected |
|---|---|---|
| B1 | 880 KiB valid JSON request | rename applied, body intact |
| B2 | 1.5 MiB request (> limit) | pass-through untransformed, intact |
| B3 | invalid JSON request | original body passed, no 500 |
| B4 | missing required header | 400 `missing_required_header` |
| B5 | small JSON response | transform applied (`status`→`success`) |
| B6 | 1.99 MiB response (> limit) | pass-through untransformed, **complete** |
| B7 | empty response | 200, 0 bytes, header present |
| B8 | transform framing | `Transfer-Encoding: chunked`, no Content-Length |
| B9 | 10 concurrent requests | 10 distinct `oss-…` correlation ids, no cross-talk |

**Scope note:** boundary tests verify the *documented* behavior of the
plugins (deterministic pass-through for over-budget bodies, streaming
budget enforcement, per-request isolation). They are **not** a
proof of resistance to every DoS scenario — load/fuzz testing is
out of scope for this release.

## Benchmark methodology

- One **fresh TCP+HTTP connection per request** (no client-side keep-alive),
  so numbers include connection setup (conservative).
- Per block: 20 warmup requests (excluded) then 100 measured requests;
  every request is **validated** (HTTP 200 + expected backend marker) —
  unvalidated samples are counted as failures.
- 3 rounds, alternating direct/kong order to cancel drift bias.
- Percentiles: nearest-rank on sorted samples.
- The client runs in a throwaway container on the **internal** network
  (no host ports, no load on unrelated host services); size is modest
  by default (100/block, concurrency 1) to stay non-destructive.
- Output: `benchmark/results/results.json` (raw samples),
  `results.csv` (one row per request), `meta.json` + `env.txt`
  (host snapshot: CPU, RAM, load, disk, docker stats, kong version).

### Reading the results

`summary.overhead_ms` / `summary.overhead_pct` are the Kong proxy
overhead vs. talking to the backend directly (mean/median/p95/p99).
A healthy baseline on a modest VM is single-digit ms overhead.

## Where results are written

- `tests/results/test-suite-report.txt` / `test-suite.json`
- `tests/results/boundary-report.txt` / `boundary.json`
- `benchmark/results/*`

All are git-ignored (keep the directories with `.gitkeep`).

## Reproducibility

- Pinned images (`kong:3.9.4`, `postgres:16.6-alpine`,
  `python:3.12.11-alpine3.21`).
- Deterministic echo backend (fixed bodies, fixed ports, stdlib only).
- Idempotent configuration: re-running `scripts/configure.sh` always
  converges to the same layout.
