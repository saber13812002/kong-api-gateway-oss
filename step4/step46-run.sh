#!/usr/bin/env bash
# STEP 4.6 — controlled deployment of the hardened step4 plugins + full
# re-verification. Run on the s52 host, from ~/kong-gateway.
#
# Usage:
#   cd ~/kong-gateway
#   git fetch origin && git checkout -B step46 origin/step46
#   bash step4/step46-run.sh
#
# Safety:
#   * deploys ONLY the plugin code of the audited commit (origin/main)
#   * recreates ONLY the kong container (echo + postgres untouched)
#   * full rollback backup (DB dump + plugin files + admin snapshot) first
#   * stops with FATAL on any integrity mismatch
set -uo pipefail

ADMIN="http://127.0.0.1:18001"
KONG_C=kong-gw-trial-kong
ECHO_C=kong-gw-trial-echo
DB_C=kong-gw-trial-db
EXPECTED_SHA=9556d5e76465ab856988d47d14a29fcae865198e
PREV_SHA=0540d41                       # last pre-audit (pre-hardened) commit
LOG=/tmp/step46-run.log
REPORT=step4/results/step46-report.txt

mkdir -p step4/results
exec > >(tee "$LOG") 2>&1

step() { echo; echo "=== $1 ==="; }
fatal() { echo "FATAL: $1"; echo "FATAL: $1" >> "$REPORT" 2>/dev/null; exit 1; }

echo "STEP 4.6 started $(date -u +%FT%TZ) on $(hostname)"
: > "$REPORT"

# ============================================================ A. preflight
step "A0. git state — deploy must come from the audited commit"
cd "$HOME/kong-gateway" || fatal "repo missing at ~/kong-gateway"
git fetch origin --quiet || fatal "git fetch failed"
ORIG=$(git rev-parse origin/main)
HEAD_NOW=$(git rev-parse HEAD)
echo "origin/main = $ORIG"
echo "local HEAD  = $HEAD_NOW"
# Rule-9 gate: the DEPLOYED SOURCE is the plugin code; it must be byte-identical
# to the audited revision. (Newer tooling commits on main are fine as long as
# step4/plugins is untouched — which this check enforces.)
if ! git diff --quiet "$EXPECTED_SHA" HEAD -- step4/plugins; then
  fatal "step4/plugins differ from audited commit $EXPECTED_SHA — STOP (rule 9)"
fi
echo "OK: plugin sources identical to audited commit $EXPECTED_SHA"

step "A1. container health (baseline)"
docker compose ps || fatal "docker compose ps failed"
for c in "$KONG_C" "$ECHO_C" "$DB_C"; do
  s=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null)
  [ -z "$s" ] && s=$(docker inspect -f '{{.State.Status}}' "$c")
  echo "container $c: $s"
  case "$s" in healthy|running) ;; *) fatal "container $c is '$s' (need healthy/running)";; esac
done
docker exec "$ECHO_C" python3 -c "import urllib.request;print('echo /health ->',urllib.request.urlopen('http://127.0.0.1:9000/health',timeout=5).read().decode())" \
  || fatal "echo backend not answering"
KV=$(curl -fsS "$ADMIN/" | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])') || fatal "kong admin not answering"
echo "kong admin: $KV"

step "A2. pre-deploy plugin hashes (host and inside container)"
find step4/plugins -name '*.lua' | sort | xargs sha256sum | tee "$REPORT"
echo "--- inside $KONG_C (before):"
docker exec "$KONG_C" sh -c 'find /usr/local/share/lua/5.1/kong/plugins/step4-pre /usr/local/share/lua/5.1/kong/plugins/step4-post -name "*.lua" | sort | xargs sha256sum'

step "A3. baseline /test-echo route (must remain unchanged)"
BASE_BEFORE=$(curl -fsS "$ADMIN/routes?size=100" | python3 -c '
import sys, json
d = json.load(sys.stdin)
ids = [r["id"] for r in d["data"] if r.get("paths") == ["/test-echo"]]
print(",".join(ids))')
[ -n "$BASE_BEFORE" ] || fatal "baseline /test-echo route not found"
echo "baseline route id(s): $BASE_BEFORE"
curl -fsS "$ADMIN/routes?size=100" > step4/results/step46-routes-before.json
echo "probe: $(curl -fsS 'http://127.0.0.1:18080/test-echo?name=step46' | head -c 200)"

# ============================================================ B. deploy
step "B1. backup (rollback readiness)"
BK="/tmp/step46-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK/plugins"
docker exec "$DB_C" pg_dump -U kong kong > "$BK/trial_db.sql" 2>"$BK/pg_dump.err" \
  || fatal "pg_dump failed: $(cat "$BK/pg_dump.err")"
cp -a step4/plugins/step4-pre "$BK/plugins/"
cp -a step4/plugins/step4-post "$BK/plugins/"
curl -fsS "$ADMIN/plugins?size=100" > "$BK/plugins-admin.json"
cp step4/results/step46-routes-before.json "$BK/" 2>/dev/null
du -sh "$BK" | tee -a "$REPORT"
echo "backup: $BK"

step "B2. deploy — recreate ONLY the kong container (bind-mount picks up new code)"
docker compose up -d --force-recreate kong-gw || fatal "kong recreate failed"
READY=0
for i in $(seq 1 90); do
  if curl -fsS "$ADMIN/" >/dev/null 2>&1; then READY=1; echo "kong ready after ${i}s"; break; fi
  sleep 1
done
[ "$READY" = "1" ] || fatal "kong admin did not come up in 90s"
sleep 3
KV=$(curl -fsS "$ADMIN/" | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])')
echo "kong back up: $KV"

step "B3. verify deployed plugin code == audited files (rule 9 gate)"
HOST_HASHES=$(find step4/plugins -name '*.lua' | sort | while read -r f; do
  echo "$(sha256sum "$f" | cut -d' ' -f1)  $(echo "$f" | sed 's|step4/plugins/||')")
done)
CONT_HASHES=$(docker exec "$KONG_C" sh -c 'find /usr/local/share/lua/5.1/kong/plugins/step4-pre /usr/local/share/lua/5.1/kong/plugins/step4-post -name "*.lua" | sort | while read -r f; do echo "$(sha256sum "$f" | cut -d" " -f1)  $(basename "$f")"; done')
echo "$HOST_HASHES"
echo "--- inside $KONG_C (after):"
echo "$CONT_HASHES"
if [ "$HOST_HASHES" = "$CONT_HASHES" ]; then
  echo "MATCH: container plugin code == audited commit files"
else
  fatal "MISMATCH between audited files and container — STOP (rule 9). Backup at $BK"
fi

step "B4. verify NEW schema is loaded (max_body_bytes)"
SVC=$(curl -fsS -X PUT "$ADMIN/services/step46-schema-probe" \
  -H 'Content-Type: application/json' \
  -d '{"host":"kong-gw-trial-echo","port":9000,"protocol":"http","name":"step46-schema-probe"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])') || fatal "scratch service create failed"
CODE_REJECT=$(curl -s -o /tmp/step46-schema-reject.json -w '%{http_code}' \
  -X POST "$ADMIN/plugins" -H 'Content-Type: application/json' \
  -d "{\"name\":\"step4-pre\",\"service_id\":\"$SVC\",\"config\":{\"correlation_id_header\":\"X-Correlation-Id\",\"max_body_bytes\":99999999}}")
echo "out-of-range max_body_bytes -> HTTP $CODE_REJECT (expect 400): $(cat /tmp/step46-schema-reject.json | head -c 200)"
[ "$CODE_REJECT" = "400" ] || fatal "schema not enforcing max_body_bytes range — is the new schema loaded? STOP"
PID=$(curl -fsS -X POST "$ADMIN/plugins" -H 'Content-Type: application/json' \
  -d "{\"name\":\"step4-pre\",\"service_id\":\"$SVC\",\"config\":{\"correlation_id_header\":\"X-Correlation-Id\",\"max_body_bytes\":10485760}}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])') || fatal "valid max_body_bytes plugin create failed"
curl -fsS -X DELETE "$ADMIN/plugins/$PID" >/dev/null
curl -fsS -X DELETE "$ADMIN/services/$SVC" >/dev/null
echo "schema gate PASS: max_body_bytes accepted (valid) / rejected (out-of-range); probe cleaned up"

# ============================================================ C. regression
step "C. regression — STEP 4 functional suite (expect 19/19)"
MEM_BEFORE=$(docker stats --no-stream --format '{{.MemUsage}}' "$KONG_C")
echo "kong mem before: $MEM_BEFORE"
python3 step4/tests.py
RC=$?
cat step4/results/step4-report.txt
[ $RC -eq 0 ] || fatal "regression failed (rc=$RC) — stopping. Backup at $BK"

# ============================================================ D. boundaries
step "D. security boundary tests"
python3 step4/step46-boundary.py
RCB=$?
cat step4/results/step46-boundary-report.txt 2>/dev/null
[ $RCB -eq 0 ] || fatal "boundary tests failed (rc=$RCB) — stopping. Backup at $BK"

# ============================================================ E. wrap-up
step "E. observations"
MEM_AFTER=$(docker stats --no-stream --format '{{.MemUsage}}' "$KONG_C")
echo "kong mem after all tests: $MEM_AFTER"
echo "--- kong log errors/warnings (last 10 min):"
docker logs --since 10m "$KONG_C" 2>&1 | grep -iE 'error|alert|fail' | grep -v 'step46' | tail -20 || echo "(none)"

BASE_AFTER=$(curl -fsS "$ADMIN/routes?size=100" | python3 -c '
import sys, json
d = json.load(sys.stdin)
ids = [r["id"] for r in d["data"] if r.get("paths") == ["/test-echo"]]
print(",".join(ids))')
[ "$BASE_AFTER" = "$BASE_BEFORE" ] || fatal "baseline route changed! before=$BASE_BEFORE after=$BASE_AFTER"
echo "baseline /test-echo route unchanged: $BASE_AFTER"

{
  echo "STEP 4.6 — Hardened Plugin Deployment & Re-verification Report"
  echo "================================================================"
  echo "date (UTC):      $(date -u +%FT%TZ)"
  echo "host:            $(hostname)"
  echo "deployed commit: $EXPECTED_SHA (origin/main, audited)"
  echo "kong version:    $KV"
  echo "containers:      kong=$KONG_C echo=$ECHO_C db=$DB_C (echo+db untouched, kong recreated)"
  echo "regression:      $(grep RESULT step4/results/step4-report.txt 2>/dev/null || tail -1 step4/results/step4-report.txt)"
  echo "boundaries:      $(grep RESULT step4/results/step46-boundary-report.txt 2>/dev/null || echo see log)"
  echo "mem before/after: $MEM_BEFORE / $MEM_AFTER"
  echo "baseline route:  unchanged ($BASE_AFTER)"
  echo "backup (rollback): $BK"
  echo ""
  echo "ROLLBACK (if ever needed):"
  echo "  cd ~/kong-gateway && git checkout $PREV_SHA -- step4/plugins"
  echo "  docker compose up -d --force-recreate kong-gw"
  echo "  # or: cp -a $BK/plugins/step4-{pre,post} ~/kong-gateway/step4/plugins/ && recreate"
} > "$REPORT"

echo
cat "$REPORT"
echo
echo "STEP 4.6 DONE — all gates passed. Log: $LOG"
