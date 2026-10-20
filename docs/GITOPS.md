# GitOps & Configuration Lifecycle

This document describes how the gateway's configuration is exported,
reviewed, applied, backed up, restored, and rolled back. All tools are
the `scripts/` of this repository — no external CLI (decK/kong-deck) is
required, though the export format is decK-style and decK-readable.

## 1. The GitOps loop

```
            ┌────────────────────────────────────────────────┐
            │                Git repository                  │
            │  (reviewed, versioned, diff-able configuration) │
            └───────────────▲────────────────────────────────┘
                            │ 1) commit kong-gateway.yml
                            │    after review/CI
                            │ 2) scripts/import.sh (idempotent apply)
            ┌───────────────┴────────────────────────────────┐
            │              Live Kong gateway                 │
            │  scripts/export.sh reads the Admin API         │
            └────────────────────────────────────────────────┘
```

1. **Export** — `scripts/export.sh` pulls the full live inventory
   (services, routes, plugins, consumers, upstreams, targets) from the
   Admin API and writes:
   - `_export/kong-gateway.json` — canonical, machine-readable
   - `_export/kong-gateway.yml` — human/Git-friendly rendering

2. **Review** — commit the file to Git. The diff *is* the change review:
   every service/route/plugin change shows up as a line diff.

3. **Apply** — `scripts/import.sh <file>` (optionally `--dry-run` first).
   Semantics are **strictly additive/idempotent**: it creates missing
   entities and updates existing ones (matched by name); it never deletes
   entities absent from the file.

4. **Verify** — `scripts/smoke-test.sh` (and `scripts/run-tests.sh` for
   the full suite).

A live **round-trip test** (`export → import → export` must be
byte-stable modulo ordering) is part of the acceptance suite; see
PROJECT_AUDIT.md §6.2 (12/12 entities round-tripped on 53).

### Export hygiene

- The export contains **key-auth keys** (consumer credentials). The
  `_export/` directory is git-ignored by default. If you want the keys in
  Git (so a fresh import reproduces them), review the team policy first —
  prefer rotating keys after any export that leaves the repo boundary.
- Everything else in the export (plugins, routes, services) is safe to
  commit.

## 2. Backups

`scripts/backup.sh` creates a timestamped snapshot in
`_backup/<UTC-timestamp>/` (override with `BACKUP_DIR=`):

| File | Content |
|---|---|
| `kong-gateway.json` / `.yml` | declarative export of the live config |
| `pg-dump.sql` | full logical dump of the Kong database |
| `manifest.json` | provenance + **sha256 of every file** |

Snapshots are `chmod 700` — **they contain key-auth keys**. Keep the
backup directory off any shared/unencrypted volume. The newest
`BACKUP_KEEP` snapshots (default 10) are kept; older ones are pruned.

Schedule it (example cron, on the gateway host):

```cron
# nightly at 03:10 UTC
10 3 * * * cd /path/to/kong-api-gateway-oss && /usr/bin/env bash scripts/backup.sh >> _backup/cron.log 2>&1
```

## 3. Restore

`scripts/restore.sh <snapshot-dir> [--config|--database]`:

- **`--config` (default)** — applies the snapshot's declarative file via
  `import.sh`. Non-destructive, no downtime. Recovers config drift.
- **`--database`** — drops and recreates the `kong` database from
  `pg-dump.sql`. Full state rewind, including deletions made after the
  snapshot. Kong stays up but errors briefly while the DB is swapped.

Both modes **first create a fresh safety snapshot of the current state**
and verify the snapshot file's sha256 against its manifest before
restoring. A botched restore is therefore always restorable.

## 4. Rollback runbook

Goal: return the gateway to a known-good configuration after a bad
change.

```bash
# 0) see what you can roll back to
scripts/rollback.sh --list

# 1) declarative rollback (additive — the normal choice)
scripts/rollback.sh _backup/20261020-030000

# 2) the script runs: safety backup -> hash check -> import -> smoke test
# 3) verify the affected routes manually, e.g.
curl -s http://127.0.0.1:18080/test-echo

# 4) if the rollback itself misbehaves, restore the safety snapshot it
#    created (it is listed by rollback.sh --list, newest first)
```

Full state rewind (rare — e.g. a bad import that deleted data at the DB
level):

```bash
scripts/restore.sh _backup/20261020-030000 --database
```

**Never** edit the running DB by hand to "fix" a config problem —
export, fix in Git, re-import.

## 5. Multi-environment guide

The stack is namespaced entirely by `COMPOSE_PROJECT_NAME` (see
`docker-compose.yml`): containers, volumes, and the network all carry the
prefix, so dev/staging/prod can coexist on one host, and the same
repository serves all environments.

| Env | `.env` values | Rationale |
|---|---|---|
| **dev** | `COMPOSE_PROJECT_NAME=kong-gw-dev`<br>`KONG_PROXY_PORT=18080` `KONG_ADMIN_PORT=18001` | default loopback ports; throwaway data |
| **staging** | `COMPOSE_PROJECT_NAME=kong-gw-staging`<br>`KONG_PROXY_PORT=19080` `KONG_ADMIN_PORT=19001` | distinct ports; config imported from the same reviewed Git file as prod |
| **prod** | `COMPOSE_PROJECT_NAME=kong-gw-prod`<br>`KONG_PROXY_HOST=127.0.0.1` (always)<br>`KONG_PROXY_PORT=18080` | behind a TLS-terminating reverse proxy; **Admin API stays loopback** (docs/SECURITY.md) |

Rules of thumb:

1. **One repository, one declarative file per environment** (or the same
   file for staging+prod with env-specific overrides applied by import).
2. Staging receives the Git config first; only after `smoke-test.sh`
   passes there does the same file go to prod.
3. Prodspecific values that are *not* configuration (credentials) live in
   the on-host `.env` (mode 600) / CREDS files — **never in Git**.
4. Every prod apply is preceded by `backup.sh`; keep the newest snapshot
   handy for the rollback runbook above.

## 6. Clean-clone install (acceptance test)

From a fresh machine with Docker + compose v2 + curl + python3:

```bash
git clone <repo-url> kong-gw-test && cd kong-gw-test
bash scripts/setup.sh          # creates .env (auto-password), builds,
                               # starts, configures, smoke-checks
bash scripts/smoke-test.sh
bash scripts/run-tests.sh      # full deterministic suite
bash scripts/backup.sh         # first snapshot of the fresh stack
```

This exact sequence was executed as the Phase 6 acceptance test (see
PROJECT_AUDIT.md §8).
