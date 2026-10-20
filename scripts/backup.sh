#!/usr/bin/env bash
# Kong OSS release — create a backup snapshot of the live gateway.
#
# A snapshot contains:
#   kong-gateway.json / kong-gateway.yml   declarative export (export.sh)
#   pg-dump.sql                            full logical dump of the Kong DB
#   manifest.json                          provenance + sha256 of every file
#
# Snapshots land in <BACKUP_DIR>/<UTC-timestamp>/ with mode 700 — the dump
# CONTAINS key-auth keys, so treat every snapshot as secret material.
# Only the newest $BACKUP_KEEP snapshots (default 10) are kept.
#
# Usage:
#   scripts/backup.sh                        # -> $ROOT_DIR/_backup/<ts>/
#   BACKUP_DIR=/home/<user>/kong-backups scripts/backup.sh
source "$(dirname "$0")/_common.sh"

require_cmd curl
require_cmd sha256sum

: "${BACKUP_DIR:=$ROOT_DIR/_backup}"
: "${BACKUP_KEEP:=10}"
TS="$(date -u +%Y%m%d-%H%M%S)"
DEST="$BACKUP_DIR/$TS"
mkdir -p "$DEST"

log "backup snapshot $TS -> $DEST"

# 1) declarative export (reuses export.sh, pointed at the snapshot dir)
OUT_DIR="$DEST" bash "$SCRIPT_DIR/export.sh"

# 2) logical postgres dump (plain SQL, restorable with psql)
log "dumping postgres from $DB_CONTAINER"
compose exec -T db pg_dump -U kong kong > "$DEST/pg-dump.sql" \
  || die "pg_dump failed"
[ -s "$DEST/pg-dump.sql" ] || die "pg-dump.sql is empty"

# 3) manifest with provenance + integrity hashes
KONG_VERSION="$(curl -fsS "$ADMIN_URL/status" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version","?"))')"

python3 - "$DEST" "$TS" "$KONG_VERSION" <<'PYEOF' || die "manifest generation failed"
import hashlib, json, os, sys

dest, ts, kong_version = sys.argv[1], sys.argv[2], sys.argv[3]

def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

files = {}
for name in sorted(os.listdir(dest)):
    p = os.path.join(dest, name)
    if os.path.isfile(p):
        files[name] = {"size": os.path.getsize(p), "sha256": sha256(p)}

doc = {
    "type": "kong-gateway-backup",
    "version": 1,
    "created_utc": ts,
    "project": os.environ.get("COMPOSE_PROJECT_NAME", "kong-gw-oss"),
    "kong_version": kong_version,
    "admin_url": os.environ.get("ADMIN_URL", "http://127.0.0.1:18001"),
    "contents": files,
    "notes": "pg-dump.sql contains key-auth keys; keep this directory 700.",
}
with open(os.path.join(dest, "manifest.json"), "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print("  manifest.json written (%d files hashed)" % len(files))
PYEOF

chmod 700 "$DEST"

# 4) prune: keep only the newest $BACKUP_KEEP snapshots
ls -1d "$BACKUP_DIR"/*/ 2>/dev/null | sort | head -n -"$BACKUP_KEEP" \
  | while read -r old; do
      log "pruning old snapshot: $old"
      rm -rf "$old"
    done

log "backup complete: $DEST"
