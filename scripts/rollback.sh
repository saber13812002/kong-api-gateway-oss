#!/usr/bin/env bash
# Kong OSS release — roll the live gateway back to a previous snapshot.
#
# A "rollback" is a declarative restore (restore.sh --config) of a snapshot
# you choose, followed by a smoke test. It is ADDITIVE/IDEMPOTENT: entities
# present now but absent from the snapshot are NOT deleted (no destructive
# sync), so a rollback can never take down routes it does not know about.
# For a full state rewind (including deletions) use:
#   scripts/restore.sh <snapshot-dir> --database
#
# Usage:
#   scripts/rollback.sh --list               # show available snapshots
#   scripts/rollback.sh <snapshot-dir>       # config-rollback to that snapshot
#
# Runbook: see docs/GITOPS.md ("Rollback runbook").
source "$(dirname "$0")/_common.sh"

list_snapshots() {
  local d
  if ls -1d "$BACKUP_DIR"/*/ >/dev/null 2>&1; then
    printf '%-24s %8s  %s\n' "SNAPSHOT" "AGE" "FILES"
    for d in $(ls -1d "$BACKUP_DIR"/*/ | sort); do
      local name age files
      name="$(basename "$d")"
      files="$(ls -1 "$d" | wc -l)"
      age="$(python3 - "$name" <<'PYEOF'
import sys, time
name = sys.argv[1]
try:
    t = time.mktime(time.strptime(name, "%Y%m%d-%H%M%S")) - time.timezone
    dt = time.time() - t
    if dt > 86400:
        print("%dd" % int(dt // 86400))
    elif dt > 3600:
        print("%dh" % int(dt // 3600))
    else:
        print("%dm" % max(1, int(dt // 60)))
except Exception:
    print("?")
PYEOF
)"
      printf '%-24s %8s  %s\n' "$name" "$age" "$files files"
    done
  else
    echo "no snapshots found in $BACKUP_DIR"
  fi
}

if [ "${1:-}" = "--list" ] || [ -z "${1:-}" ]; then
  : "${BACKUP_DIR:=$ROOT_DIR/_backup}"
  list_snapshots
  echo
  echo "rollback to one of them:  scripts/rollback.sh <snapshot-dir>"
  exit 0
fi

SNAP="${1%/}"
[ -d "$SNAP" ] || die "snapshot dir not found: $SNAP"
[ -f "$SNAP/kong-gateway.json" ] \
  || die "no kong-gateway.json in $SNAP (not a valid snapshot)"

log "=== rollback to $SNAP (declarative, additive) ==="
bash "$SCRIPT_DIR/restore.sh" "$SNAP" --config

log "running smoke test"
bash "$SCRIPT_DIR/smoke-test.sh"

log "rollback complete — verify affected routes manually (runbook in docs/GITOPS.md)"
