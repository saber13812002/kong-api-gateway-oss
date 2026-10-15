#!/usr/bin/env bash
# STEP 3 — pre-benchmark check: wait for kong healthy, verify ulimit + route.
for i in $(seq 1 15); do
  H=$(docker inspect --format '{{.State.Health.Status}}' kong-gw-trial-kong 2>/dev/null)
  echo "t=$i: $H"
  [ "$H" = 'healthy' ] && break
  sleep 10
done
echo '=== ulimit -n inside kong (was 1024) ==='
docker exec kong-gw-trial-kong bash -c 'ulimit -n'
echo '=== Admin API check ==='
curl -s -o /dev/null -w 'admin_http=%{http_code}\n' http://127.0.0.1:18001/
echo '=== route still works ==='
curl -s -o /dev/null -w 'echo_http=%{http_code}\n' http://127.0.0.1:18080/test-echo
echo 'PRECHECK_DONE'
