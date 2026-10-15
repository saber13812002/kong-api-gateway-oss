#!/usr/bin/env bash
# STEP 3 — benchmark runner (executed on s52 from ~/kong-gateway).
# 1. Environment snapshot (CPU/RAM/swap/disk/ulimits/usage baseline)
# 2. Build temp bench client image (pinned python:3.12.11-alpine3.21)
# 3. Run 3 rounds x 100 measured requests per path (direct vs kong)
#    inside a temp container on the internal kong-gw-trial-net
# 4. Save results.json + results.csv to benchmark/results/
# 5. Verify existing services untouched, remove temp container
set -uo pipefail
cd ~/kong-gateway
RES=benchmark/results
mkdir -p "$RES"

echo '=== TASK A: environment snapshot (before test) ==='
python3 - <<'EOF' > "$RES/meta.json"
import json, subprocess
def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
meta = {
    "target_host": "s52 (172.20.1.52)",
    "bench_client": "temp container kong-gw-trial-bench-run on internal network kong-gw-trial-net (no host ports)",
    "bench_image_base": "python:3.12.11-alpine3.21",
    "kong_version": sh(["docker", "exec", "kong-gw-trial-kong", "kong", "version", "-q"]) or "3.9.4",
    "docker_version": sh(["docker", "--version"]),
    "compose_project": "kong-gw-trial",
    "concurrency": 1,
    "measured_requests_per_round": 100,
    "warmup_excluded_per_round": 20,
    "rounds": 3,
    "measured_total_per_path": 300,
}
print(json.dumps(meta, indent=2))
EOF
cat "$RES/meta.json"
{
  echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "os: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2)"
  echo "cpu_cores: $(nproc)"
  echo "loadavg: $(cut -d' ' -f1-3 /proc/loadavg)"
} | tee "$RES/env.txt"
free -h | tee -a "$RES/env.txt"
df -h / | tail -1 | tee -a "$RES/env.txt"
{
  echo '--- disk io (2 samples) ---'
  command -v iostat >/dev/null && iostat -x 1 2 | tail -n 15 || echo 'iostat not installed; using /proc/loadavg only'
  echo '--- ulimits (host shell soft/hard) ---'
  echo "soft=$(ulimit -n) hard=$(ulimit -Hn)"
  echo '--- ulimit -n inside kong container (post-fix) ---'
  docker exec kong-gw-trial-kong bash -c 'ulimit -n'
  echo '--- docker stats baseline (kong stack) ---'
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' kong-gw-trial-kong kong-gw-trial-db kong-gw-trial-echo
  echo '--- container count baseline ---'
  echo "running=$(docker ps -q | wc -l)"
} | tee -a "$RES/env.txt"

echo
echo '=== build bench client image (temp) ==='
docker compose -p kong-gw-trial build kong-gw-bench 2>&1 | tail -n 3

echo
echo '=== run benchmark (3 rounds, alternating order, 100 measured/block) ==='
time docker run --rm --name kong-gw-trial-bench-run \
  --network kong-gw-trial-net \
  -v "$PWD/benchmark/results:/out" -w /out \
  kong-gw-trial-bench:1.0 \
  python /app/bench.py /out/results.json /out/results.csv

echo
echo '=== verify services after benchmark ==='
echo "running=$(docker ps -q | wc -l) (expect same as baseline)"
docker ps --filter name=kong-gw-trial --format 'table {{.Names}}\t{{.Status}}'
curl -s -o /dev/null -w 'admin_api_http=%{http_code}\n' http://127.0.0.1:18001/
curl -s -o /dev/null -w 'proxy_echo_http=%{http_code}\n' http://127.0.0.1:18080/test-echo
echo 'RUN_SH_DONE'
