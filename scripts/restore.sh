#!/usr/bin/env bash
# Kong OSS release — restore the gateway from a backup snapshot.
#
# Two independent restore paths, chosen by flag:
#
#   --config   (default)  apply the declarative export from the snapshot
#                         via import.sh (additive/idempotent; no downtime,
#                         no deletes). Best for recovering config drift.
#
#   --database             restore the FULL pg dump (drop + recreate the
#                         'kong' database). Destructive: all current DB
#                         state is replaced by the snapshot. The stack must
#                         be running; Kong is briefly unavailable while the
#                         DB is swapped (the stack keeps running, requests
#                         get 500s until Kong re-connects).
#
# Before ANY restore this script automatically creates a new backup
# snapshot (so a botched restore itself is restorable).
#
# Usage:
#   scripts/restore.sh <snapshot-dir>                # --config
#   scripts/restore.sh <snapshot-dir> --config
#   scripts/restore.sh <snapshot-dir> --database
#   BACKUP_DIR=... scripts/restore.sh ...            # where the safety
#                                                    # snapshot is written
source "$(dirname "$0")/_common.sh"

SNAP="${1:-}"
MODE="${2:---config}"

[ -n "$SNAP" ] || die "usage: restore.sh <snapshot-dir> [--config|--database]"
[ -d "$SNAP" ] || die "snapshot dir not found: $SNAP"

case "$MODE" in
  --config)   CONF="$SNAP/kong-gateway.json" ;;
  --database) CONF="$SNAP/pg-dump.sql" ;;
  *) die "unknown mode: $MODE (expected --config or --database)" ;;
esac
[ -f "$CONF" ] || die "expected file not found in snapshot: $CONF"

if [ "$MODE" = "--database" ]; then
  log "WARNING: --database replaces the ENTIRE Kong database."
  log "Continuing in 10s (Ctrl-C to abort)..."
  sleep 10
fi

# ---- safety snapshot of the CURRENT state before touching anything -------
log "creating pre-restore safety snapshot"
bash "$SCRIPT_DIR/backup.sh"

# ---- verify manifest hashes of the file we are restoring -----------------
python3 - "$SNAP" "$(basename "$CONF")" <<'PYEOF' || die "snapshot integrity check FAILED — aborting"
import hashlib, json, os, sys

snap, fname = sys.argv[1], sys.argv[2]
man_path = os.path.join(snap, "manifest.json")
if not os.path.isfile(man_path):
    print("  (no manifest.json in snapshot — skipping hash check)")
    sys.exit(0)

man = json.load(open(man_path))
entry = man.get("contents", {}).get(fname)
if not entry:
    print("  %s not listed in manifest — skipping hash check" % fname)
    sys.exit(0)

h = hashlib.sha256()
with open(os.path.join(snap, fname), "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
actual = h.hexdigest()
if actual != entry["sha256"]:
    print("  sha256 MISMATCH for %s: manifest=%s actual=%s" % (fname, entry["sha256"], actual))
    sys.exit(1)
print("  sha256 OK for %s" % fname)
PYEOF

# ---- the restore itself ----------------------------------------------------
if [ "$MODE" = "--config" ]; then
  bash "$SCRIPT_DIR/import.sh" "$CONF"
else
  log "restoring database from $CONF"
  compose exec -T db psql -U kong -d postgres \
    -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS kong WITH (FORCE);" \
    -c "CREATE DATABASE kong OWNER kong" \
    || die "drop/create database failed"
  compose exec -T db psql -U kong -d kong -v ON_ERROR_STOP=1 < "$CONF" \
    || die "psql restore failed"
  log "database restored; Kong may need a moment to reconnect (it polls the DB)"
fi

# ---- post-restore verification --------------------------------------------
wait_admin 60
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$PROXY_URL/test-echo" || true)"
if [ "$code" = "200" ]; then
  log "restore verified: proxy /test-echo -> 200"
else
  log "WARNING: proxy /test-echo returned '$code' after restore — inspect the stack"
fi
log "restore complete (mode: $MODE)"
