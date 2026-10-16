#!/usr/bin/env bash
# Kong OSS release — latency/throughput benchmark.
#
# Method (see bench/bench.py):
#   * one fresh TCP+HTTP connection per request
#   * per block: WARMUP warmup (excluded) + N measured requests, all
#     validated (HTTP 200 + expected backend marker)
#   * ROUNDS rounds, alternating direct/kong order to cancel drift bias
#   * percentiles: nearest-rank on sorted samples
#
# The client runs in a throwaway container on the internal Docker
# network (no host ports, no load on other host services). Output:
#   benchmark/results/results.json  raw samples
#   benchmark/results/results.csv   one row per request
#   benchmark/results/meta.json     environment snapshot
#   benchmark/results/env.txt       host resource snapshot
#
# Defaults are deliberately modest (100 measured/block, concurrency 1);
# raise BENCH_N / BENCH_CONCURRENCY only on a server sized for it.
source "$(dirname "$0")/_common.sh"

RES="$ROOT_DIR/benchmark/results"
mkdir -p "$RES"

# ------------------------------------------------- preflight -----------
[ "$(container_health "$KONG_CONTAINER")" = "healthy" ] \
  || die "kong container is not healthy; run scripts/setup.sh first"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$PROXY_URL/test-echo")"
[ "$code" = "200" ] || die "proxy /test-echo returned $code (route missing? run scripts/configure.sh)"

# ------------------------------------------------- env snapshot --------
KONG_VERSION="$(docker exec "$KONG_CONTAINER" kong version 2>/dev/null | head -1 | awk '{print $2}' || echo unknown)"
{
  echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "os: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || uname -s)"
  echo "hostname: $(hostname)"
  echo "cpu_cores: $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo n/a)"
  echo "loadavg: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || uptime)"
  echo "kong_version: $KONG_VERSION"
  echo "compose_project: $COMPOSE_PROJECT_NAME"
  echo "measured_requests_per_block: ${BENCH_N:-100}"
  echo "warmup_excluded_per_block: ${BENCH_WARMUP:-20}"
  echo "rounds: ${BENCH_ROUNDS:-3}"
  echo "concurrency: ${BENCH_CONCURRENCY:-1}"
} | tee "$RES/env.txt"
free -h 2>/dev/null | tee -a "$RES/env.txt" || true
df -h / 2>/dev/null | tail -1 | tee -a "$RES/env.txt" || true
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' \
  "$KONG_CONTAINER" "$DB_CONTAINER" "$ECHO_CONTAINER" 2>/dev/null | tee -a "$RES/env.txt" || true

# ------------------------------------------------- build bench ---------
compose build bench >/dev/null
BENCH_IMAGE="${COMPOSE_PROJECT_NAME}-bench:1.0"

# ------------------------------------------------- run -----------------
log "running benchmark (BENCH_N=${BENCH_N:-100} BENCH_ROUNDS=${BENCH_ROUNDS:-3} BENCH_CONCURRENCY=${BENCH_CONCURRENCY:-1})"
time docker run --rm --name "${COMPOSE_PROJECT_NAME}-bench-run" \
  --network "$NETWORK_NAME" \
  -e BENCH_DIRECT_HOST="${COMPOSE_PROJECT_NAME}-echo" \
  -e BENCH_KONG_HOST="${COMPOSE_PROJECT_NAME}-kong" \
  -e BENCH_BACKEND_NAME="$ECHO_BACKEND_NAME" \
  -e BENCH_N="${BENCH_N:-100}" \
  -e BENCH_WARMUP="${BENCH_WARMUP:-20}" \
  -e BENCH_ROUNDS="${BENCH_ROUNDS:-3}" \
  -e BENCH_CONCURRENCY="${BENCH_CONCURRENCY:-1}" \
  -v "$RES:/out" -w /out \
  "$BENCH_IMAGE" \
  python /app/bench.py /out/results.json /out/results.csv

# ------------------------------------------------- postflight ----------
echo
echo "=== post-benchmark verification ==="
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$PROXY_URL/test-echo")"
echo "proxy /test-echo: $code"
[ "$code" = "200" ] || die "proxy degraded after benchmark"
echo "admin API: $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$ADMIN_URL/")"

echo
echo "=== summary ==="
python3 - "$RES/results.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["summary"]
for p in ("direct", "kong"):
    r = s[p]
    print(f"{p:7} mean={r['mean_ms']:8.3f} ms  p50={r['median_ms']:8.3f}  "
          f"p95={r['p95_ms']:8.3f}  p99={r['p99_ms']:8.3f}  "
          f"max={r['max_ms']:8.3f}  rps={r.get('rps', float('nan'))}")
o = s["overhead_ms"]
print(f"overhead mean={o['mean']:+.3f} ms  p95={o['p95']:+.3f} ms  p99={o['p99']:+.3f} ms")
fails = sum(b["failed"] for rd in d["rounds"] for b in rd["blocks"])
print(f"failed requests across all blocks: {fails}")
EOF
echo "[bench] results: benchmark/results/"
