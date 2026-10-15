#!/usr/bin/env bash
# STEP 4 — full run: deploy custom plugins, configure (x2 = idempotency
# proof), run all functional tests, final state verification.
# Run on s52 from ~/kong-gateway (scripts live in ./step4).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "########## STEP 4 RUN $(date -u +%Y-%m-%dT%H:%M:%SZ) ##########"
echo
echo "### 0) pre-state"
echo "containers running before: $(docker ps -q | wc -l)"
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'kong-gw-trial' || true
curl -fsS -o /dev/null -w "baseline /test-echo pre: HTTP %{http_code}\n" \
  "http://127.0.0.1:18080/test-echo?name=preflight"

echo
echo "### 1) deploy (echo rebuild + kong recreate with plugin mounts)"
bash step4/deploy.sh

echo
echo "### 2) configure (first run)"
bash step4/configure.sh

echo
echo "### 3) configure (second run — idempotency proof)"
bash step4/configure.sh

echo
echo "### 4) functional tests (7 scenarios + baseline integrity)"
TEST_RC=0
python3 step4/tests.py || TEST_RC=$?

echo
echo "### 5) post-state"
echo "containers running after: $(docker ps -q | wc -l)  (must equal pre-count)"
curl -fsS -o /dev/null -w "baseline /test-echo post: HTTP %{http_code}\n" \
  "http://127.0.0.1:18080/test-echo?name=postcheck"
echo "public listeners on s52 (must be unchanged set):"
ss -ltnp 2>/dev/null | awk 'NR>1 {print $4}' | grep -E ':(80|443|8000|8001|8443|8444)\b' || echo "  (none of 80/443/8000/8001/8443/8444 publicly bound)"
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'kong-gw-trial' || true

echo
if [ "$TEST_RC" -eq 0 ]; then
  echo "########## STEP 4 RUN COMPLETE: ALL TESTS PASSED ##########"
else
  echo "########## STEP 4 RUN COMPLETE: FAILURES PRESENT — see step4/results/ ##########"
  exit 1
fi
