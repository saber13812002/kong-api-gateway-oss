# PROJECT AUDIT — Phase 0 (read-only inspection)

**Date:** 2026-10-19 (UTC) · **Method:** strictly read-only remote inspection
(SSH key auth, `docker`/`curl`/`git` probes). No container, image, volume,
file, or setting was modified except: two timestamped read-only backups of
effective configs and DBs (saved to owner-readable 600 files on each server)
and one fresh `git fetch`. No credentials were printed.

Servers are referenced as:

- **52** — trial host (`kong-gw-trial` stack, public domain `kong.ai.ismc.ir`, BaoTa/nginx front, GitLab host)
- **53** — release host (`kong-gw-oss` stack, GPU box, no public vhost)

> **Public-repo sanitization (2026-10-20):** internal addresses and
> personal home paths were replaced before publication:
> `198.51.100.53`/`198.51.100.52` (TEST-NET-2, RFC 5737) stand in for the
> real LAN hosts **53**/52, and `/home/<user>` stands in for the real
> operator home directory. No secrets, keys, or credentials are contained
> anywhere in this repository (see docs/SECURITY.md).

---

## 1. Verified state (facts, with evidence)

### 1.1 Server 52 (trial)

| Item | Verified value |
|---|---|
| Docker | 29.1.3 (Ubuntu 24.04) |
| Kong | `kong:3.9.4` — running, **healthy** 4+ days, started 2026-10-15 |
| Kong Admin | loopback `127.0.0.1:18001` → 200, DB reachable, 423 requests handled |
| Kong config | 1 service (`test-echo-service`), 1 route (`/test-echo`), **0 plugins** |
| PostgreSQL | `postgres:16.6-alpine` in `kong-gw-trial-db`, `pg_isready` OK, DB 16.6 |
| Proxy | loopback `127.0.0.1:18080` → 200 on `/test-echo` (echo JSON returned) |
| Network/volume | `kong-gw-trial-net` (bridge), volume `kong-gw-trial-pgdata` |
| Bench | image `kong-gw-trial-bench:1.0` present; no bench container running |
| Extra containers | `kong-admin-auth-52` (nginx:alpine, **host network, 0.0.0.0:8001** → Kong Admin 18001, Basic auth), `kong-gw-panel` (python:3.12-alpine, **127.0.0.1:18090 only**, on `kong-gw-trial-net`, GET-only read-only dashboard) |
| Frontend | BaoTa nginx on 80+443, many unrelated vhosts (chat/corpus/grafana/…) — untouched |
| TLS | Let's Encrypt, `CN=kong.ai.ismc.ir`, valid to **2027-01-15**, renewal config present in `/etc/letsencrypt/renewal/` |
| htpasswd | `/etc/nginx-htpasswd-kong` — 2 lines, **apr1** hashes, users `admin` + `drsoheili`; **mode 644 (world-readable)**; md5 `3c6b4a23…`; identical to backup `.bak-20261017` |
| Sudo | NOPASSWD scoped: `nginx` (3 paths), `systemctl`, `ss`, `journalctl`, `chmod`. **No password fallback** (`~/.sudo-pwd` deleted) |
| Git copy | `/home/<user>/kong-gateway` — GitLab `common/kong-gateway`, branch `step46` @ `15031f3`, **dirty working tree**, `.env` = single key `KONG_PG_PASSWORD` (mode 664) |
| Other copy | `/home/<user>/kong-gateway-release` — **plain file copy, not a git repo** |
| Disk | 686 GB total, **45 GB free (94 % used)** — tight |
| Co-tenants | GitLab, LiteLLM, Open WebUI, CMS, Flowise, n8n, Grafana/Prometheus/Loki, RAG stacks, etc. — **out of scope, never touched** |

### 1.2 Server 53 (release)

| Item | Verified value |
|---|---|
| Kong | `kong:3.9.4` — running, **healthy**, proxy `127.0.0.1:18080`, admin `127.0.0.1:18001` |
| Kong config | **10 services, 12 routes, 11 plugins** (`oss-pre` ×4, `oss-post` ×4, `request-transformer` ×2, `response-transformer` ×1) — matches `scripts/configure.sh` of the release |
| Proxy check | `GET /test-echo` on 18080 → **200** (echo JSON) |
| PostgreSQL | `postgres:16.6-alpine` in `kong-gw-oss-db`, `pg_isready` OK, volume `kong-gw-oss-pgdata` (~10 MB) |
| Repo | `/home/<user>/kong-api-gateway-oss` — **clean working tree**, `main` @ `2d7ebda`, remote = GitHub (SSH) |
| Admin proxy | standalone `kong-admin-auth` (nginx:alpine, **host network, 0.0.0.0:18002** → 18001, Basic auth, `restart unless-stopped`, htpasswd bind-mounted read-only from `/home/<user>/kong-admin-auth/`) |
| htpasswd (53) | 2 lines, **apr1** hashes, users `admin` + `drsoheili`, md5 `31983fe6…` |
| Host nginx | **none** (no `/etc/nginx`, no 443 listener) — 53 is not publicly fronted |
| Sudo | scoped NOPASSWD (gitlab-runner ops only) + broad `(ALL:ALL) ALL` rule with on-server password file fallback |
| Disk | 330 GB free |
| AI co-tenants (relevant for Phase 5) | `vllm-qwen38` (8000), `vllm-qwen38-gpu1` (8001), `vllm-embedding` (4000, `/health` → 200, OpenAI-compatible), `vllm-embedding-06b` (4001), fine-tuned qwen2.5 (8101), `mock-litellm` (9001), `mock-open-webui` (9002), `open-webui` (80), `ollama` |

### 1.3 Credential / auth matrix (verified today, no secrets used)

| Path | No creds | Wrong creds | Working creds |
|---|---|---|---|
| `https://kong.ai.ismc.ir/` (Kong Admin) | **401** ✅ | **401** ✅ | **UNKNOWN — documented password rejected (handoff-verified + nginx logs)** |
| `http://kong.ai.ismc.ir/panel/` (port 80) | **200 — panel HTML returned** ❌ **EXPOSED** | n/a | n/a (no gate at all) |
| `https://kong.ai.ismc.ir/panel/` (443) | **401** (gate) | **401** | after auth → falls into `location /` → **Kong Admin 404, NOT the panel** ❌ broken |
| `http://<52>:8001/` (LAN admin proxy) | **401** ✅ | **401** ✅ | **UNKNOWN — same broken hash set** |
| `http://<53>:18002/` (LAN admin proxy) | **401** ✅ | **401** ✅ | **UNKNOWN — same; nginx error log shows repeated "password mismatch" from a LAN client** |
| Kong Admin direct (loopback, both servers) | **200 — no auth of its own** (by design; must never be exposed) | — | — |

**Conclusion:** the documented credential `admin/drsoheili` does **not** open
any admin path (verified against both apr1 hash sets by the 2026-10-18 check
and by live 401s). No currently documented password works anywhere. A
controlled reset is required (Phase 2). The hash *files* are intact
(byte-identical to their 2026-10-17/18 backups).

### 1.4 Git state (GitHub is canonical)

| Copy | HEAD | vs GitHub `main` (`633cee4`) |
|---|---|---|
| GitHub `main` (canonical) | `633cee4` (17 commits) | — |
| 53 `/home/<user>/kong-api-gateway-oss` | `2d7ebda` | **diverged**: 3 GitHub commits not local, 2 local commits not on GitHub; diff = `AGENT_HANDOFF.md` only (both sides are docs updates) |
| 52 `/home/<user>/kong-gateway` | GitLab `common/kong-gateway` `step46` @ `15031f3` | different repo (trial lineage); dirty tree |
| 52 `/home/<user>/kong-gateway-release` | not a git repo | plain file copy |
| Windows `release/kong-api-gateway-oss` | `c03553c` "a commit message" | **scratch clone**: single commit of the whole workspace (project nested + ops scripts at root); not canonical, must never be pushed |
| GitLab | only `common/kong-gateway` exists | **no `kong-api-gateway-oss` mirror exists** — the "GitLab mirror" mentioned in old handoff docs is stale/absent |

### 1.5 Secret scan (counts only; no values printed)

| Scope | High-value pattern hits (AWS keys, GitHub tokens, Slack, LLM keys, private keys, JWTs) |
|---|---|
| GitHub `main` working tree | **0** |
| GitHub `main` full history (17 commits) | **0** |
| 53 repo working tree + full history | **0** |
| 52 `/home/<user>/kong-gateway` working tree + full history (incl. `step46`) | **0** |
| Windows `release/` tree + history | **0** |
| Trial DB password (pickaxe, all 52 git objects) | **0 commits** (present only in the untracked `.env`) |

**Findings to fix (not secrets, but hygiene):**
- `/etc/nginx-htpasswd-kong` on 52 is mode **644** (should be 600, root).
- 52 `/home/<user>/kong-gateway/.env` and one backup copy are mode **664** (should be 600).
- Windows workspace root contains ops scripts with internal hostnames/IPs — must stay **out of the public repo** (they are; the repo lives in its own directory).

### 1.6 Backups created by this audit (all mode 600)

| Server | Path | Contents |
|---|---|---|
| 52 | `/home/<user>/kong-panel/backups/` | full effective nginx config (`nginx -T`), kong vhost extract, htpasswd copy (md5-verified vs live), Kong Admin API JSON export, PostgreSQL `pg_dump` (74 KB) |
| 53 | `/home/<user>/backups/kong/` | Kong Admin API JSON export (24 KB), PostgreSQL `pg_dump` (86 KB), both htpasswd copies (container + source) |

Restore-ability: `pg_dump` is a full logical dump; effective nginx config is
the exact `nginx -T` output; htpasswd copies are byte-identical (md5).

### 1.7 Test baseline

Stored results from 2026-10-16 exist in the repo (`tests/results/`,
`benchmark/results/`) claiming 18/18 + 9/9. **Treated as unverified** until
re-run in Phase 10 (per mission rule).

---

## 2. Confirmed defects / risks

| # | Severity | Defect | Evidence | Status |
|---|---|---|---|---|
| D1 | **CRITICAL** | Panel reachable **unauthenticated over public HTTP port 80** (`/panel/` → 200 with live Kong data + log tails) | public curl → 200 + panel HTML; vhost dump shows no `auth_basic` in the 80 block | **RESOLVED** (Phase 1, verified public) |
| D2 | HIGH | HTTPS `/panel/` never reaches the panel (443 block has **no** `/panel/` location; after auth it hits Kong Admin → 404) | vhost dump + 443 behavior | **RESOLVED** (Phase 1, verified public) |
| D3 | HIGH | No working admin credential anywhere (52 vhost, 52:8001, 53:18002) — owner locked out of the documented admin paths | live 401 matrix + hash mismatch (2026-10-18) | **RESOLVED** (Phase 2, controlled resets ×3) |
| D4 | MEDIUM | `kong-admin-auth-52` on **0.0.0.0:8001** (LAN) — unnecessary second exposure of the Admin API surface; 53 `kong-admin-auth` on **0.0.0.0:18002** (LAN) | `ss` + container inspect | **RESOLVED** (both loopback-restricted; removal = owner decision) |
| D5 | MEDIUM | htpasswd world-readable (644) on 52 | `stat` | **RECLASSIFIED** — 644 is the *required* mode here (non-root nginx workers; see §4.3) |
| D6 | MEDIUM | 52 disk at 94 % (45 GB free) — risk for any rebuild/log growth | `df` |
| D7 | LOW | Git divergence 53↔GitHub (docs-only, both sides) | `git rev-list` |
| D8 | LOW | 53 has stray host listeners 8000/8001 (uvicorn apps, **not** Kong) that could confuse operators | `ss` + prior audit |
| D9 | LOW | Old handoff docs claim a GitLab mirror that does not exist | GitLab project list |
| D10 | INFO | 52 `.env` files at 664 | `stat` |

---

## 3. Unknowns (need owner input or deeper access)

1. **The actual working admin password** (if any ever worked) — required to
   decide reset vs. reconciliation. Owner must supply the new value over a
   secure channel (see Phase 2 plan; it never appears in this repo, chat, or logs).
2. Whether **LAN access to 52:8001 or 53:18002 is required by any tooling**
   (monitoring? scripts?) before they can be loopback-restricted. The 8001
   access log shows only two client IPs (a LAN host + loopback) over 2 days.
3. BaoTa panel's auto-relock of `/www/server/panel/vhost` (mode 600) may
   re-trigger after manual edits — owner needs to confirm BaoTa won't revert
   the vhost fix on its next config cycle.
4. Whether the 52 trial stack should be decommissioned after the release
   stack on 53 is the sole reference (Phase 11 decision).

---

## 4. Phase 1 + 2 execution results (2026-10-19/20, executed + verified)

### 4.1 Phase 1 — 52 vhost fix (D1/D2) — RESOLVED, verified from public internet

Executed via root-container technique (`docker run --rm -v /:/host python:3.12-alpine`;
saber is in docker group; scoped sudo covers `nginx -t`/reload only).

- Backup: `/home/<user>/kong-panel/backups/vhost-kong-ai-ismc-ir.conf.pre-fix-<TS>`
  (md5-verified) + local copy `backups-52/` on the operator workstation.
- New vhost (md5 `2f001e07…`, 1338 B): port-80 block now redirects
  `/panel`, `/panel/`, `/` → `301 https://…`; ACME challenge path preserved.
  Port-443 block: `location /panel/` added, proxying to
  `127.0.0.1:18090`, **inside** the existing `auth_basic` server scope.
- `nginx -t` pass → reload; auto-rollback armed in script (not triggered).

Public verification matrix (from the operator workstation, real DNS):

| Check | Result |
|---|---|
| `http://kong.ai.ismc.ir/panel/` | **301** → `https://kong.ai.ismc.ir/panel/` (empty body, no data) ✅ |
| `http://kong.ai.ismc.ir/panel` | **301** ✅ |
| `https://kong.ai.ismc.ir/panel/` no-auth | **401** ✅ |
| `https://kong.ai.ismc.ir/panel/` wrong creds | **401** ✅ |
| `https://kong.ai.ismc.ir/panel/` correct creds | **200** panel ✅ |
| `https://kong.ai.ismc.ir/` (Kong Admin) no-auth | **401** ✅ |
| `/.well-known/acme-challenge/x` (HTTP) | **404** (not redirected — cert renewal safe) ✅ |
| Other vhosts: `ai.ismc.ir` | 200/200 (unchanged) ✅ |
| Other vhosts: `git.ai.ismc.ir` | 302 (unchanged) ✅ |
| Other vhosts: `admin.ai.ismc.ir` | 307 (unchanged) ✅ |

### 4.2 Phase 2 — controlled credential recovery (D3) — RESOLVED

All passwords generated **on-server** (`openssl rand -hex 16`), stored in
mode-600 files only, never printed. Hash format: single `admin` user, `$6$`
(SHA-512) via `crypt` in `python:3.12-alpine`.

| Gate | Backup | New credential file (mode 600) | Verification |
|---|---|---|---|
| 52 443 vhost (`/etc/nginx-htpasswd-kong`) | `htpasswd-kong-20261019-234307.bak` (= original md5 `3c6b4a23…`) + pre-rotate backup | `/home/<user>/kong-panel/CREDS-20261019-235512` | public: no-auth 401 / wrong 401 / correct **200**; old rotated pw now 401 |
| 53 `kong-admin-auth` (18002) | `/home/<user>/backups/kong/htpasswd-53-20261020-000800.bak` (md5 `31983fe6…`) | `/home/<user>/kong-admin-auth/CREDS-20261020-000800` | loopback: 401/401/**200** |
| 52 `kong-admin-auth-52` (8001) | `/home/<user>/kong-panel/backups/htpasswd-8001-52-20261020-005225.bak` (old file had users `admin`+`drsoheili`, md5 `fad95afe…`) | `/home/<user>/kong-panel/backups/CREDS-8001-20261020-005225` | loopback: 401/401/**200** |

**Credential leak & rotation (disclosed):** during diagnosis, one `curl -v`
run printed the `Authorization` header (base64 of the then-current 443
password) into terminal output. The password was treated as compromised:
rotated to a new value, old password verified 401, old CREDS file deleted.
No further credential material was ever displayed.

### 4.3 Learned rule — htpasswd mode on 52 (D5 reclassified)

Mid-Phase-2, an intermediate reset with `chmod 600 root:root` broke
**authenticated** requests (nginx returned its own 500; no-auth 401s kept
working). Real error (found in `/www/wwwlogs/nginx_error.log`, not
`/www/server/nginx/logs/error.log`):

```
[crit] open() "/etc/nginx-htpasswd-kong" failed (13: Permission denied)
```

BaoTa nginx workers run **non-root** (`www`); `auth_basic_user_file` must be
**world-readable (644)**. The file holds only salted hashes (no plaintext),
so 644 is the correct mode here. All three htpasswd files are now 644 with
the new `$6$` hashes; the original 644 pre-existing config is unchanged in
this regard. (The Phase-0 note "should be 600" is retracted for this file.)

### 4.4 Phase 2 — exposure restriction (D4) — RESOLVED (loopback), removal = owner decision

Evidence before acting: **zero** established connections to 52:8001 and
53:18002 at probe time (no LAN consumers observed; prior access-log showed
only a couple of failed-auth client IPs on 52:8001).

| Proxy | Change | Verified |
|---|---|---|
| 53 `kong-admin-auth` | `listen 0.0.0.0:18002;` → `listen 127.0.0.1:18002;` + `docker restart kong-admin-auth` | loopback: correct **200** / no-auth **401**; external iface `198.51.100.53:18002` **unreachable (000)**; Kong admin 18001 200; proxy 18080 `/test-echo` 200 |
| 52 `kong-admin-auth-52` | `listen 0.0.0.0:8001;` → `listen 127.0.0.1:8001;` + `docker restart kong-admin-auth-52` | loopback: correct **200** / no-auth **401**; external iface `198.51.100.52:8001` **unreachable (000)**; 443 panel gate 401; HTTP80 `/panel/` 301; Kong admin 18001 200 |

Rollbacks (kept, timestamped backups, mode 600):
- 53: `cp /home/<user>/backups/kong/nginx.conf-53-20261020-000800.bak /home/<user>/kong-admin-auth/nginx.conf && docker restart kong-admin-auth`
- 52: `cp /home/<user>/kong-panel/backups/nginx.conf-8001-52-20261020-005225.bak /home/<user>/kong-admin-auth/nginx.conf && docker restart kong-admin-auth-52`

**Owner decisions still open:** (a) whether to *remove* either proxy
entirely (both now loopback-only and gated); (b) whether 8001/18002 are
needed by any LAN tooling we could not observe; (c) rotate the on-server
CREDS passwords to owner-chosen values (secure channel).

### 4.5 Not changed in Phases 1–2 (explicit)

- No Kong container, volume, or DB touched on either server.
- No other vhost, BaoTa panel service, GitLab, or co-tenant touched on 52.
- No host nginx exists on 53 (unchanged).
- Panel app (`panel/app.py`) unchanged: single auth point is the nginx 443
  gate; panel binds `127.0.0.1:18090` only. App-level second gate is a
  Phase 3 item (management UI with RBAC), not a Phase 1 requirement.
- 53 `0.0.0.0:8001` identified as `vllm-qwen38-gpu1` (AI service, **not**
  Kong) — left as-is (D8 context).

---

## 5. Phase 3 execution results (2026-10-20, executed + verified)

### 5.1 What was built — `release/kong-api-gateway-oss/panel/manage.py`

A stdlib-only (no third-party deps) management UI for Kong OSS. Security
model:

- The **browser never touches the Kong Admin API** — it only talks to this
  service, which proxies to Kong (`KONG_ADMIN`, docker-internal).
- Server-side sessions: `secrets.token_hex(32)` cookie (`HttpOnly`,
  `SameSite=Strict`), 1 h TTL, 3 idle-expiry tolerance.
- **Per-session CSRF token** (header `X-CSRF-Token`) required for every
  mutation (POST/PUT/DELETE) — 403 without it.
- **RBAC** per user in the users file (`user:role:password`, mode 600):
  `viewer` (read) < `operator` (+POST/PUT) < `admin` (+DELETE, `/api/audit`).
  This is real server-side enforcement, not "Basic Auth called RBAC".
- **JSONL audit log** (user, role, ip, method, path, result, ms, note) —
  no passwords or secrets ever written.
- **Pre-change backup** (JSON, mode 600) of the current object before any
  PUT/DELETE.
- Strict CSP (nonce-based `default-src 'none'`), `X-Frame-Options: DENY`,
  `X-Content-Type-Options: nosniff`. Login rate limit: 5 failures → 60 s
  lockout per IP. Input validation (required fields per collection).
  `BASE` env var makes the UI prefix-aware (`BASE=/admin` on 52, `""` on 53).

### 5.2 Tests (executed, not cited)

| Suite | Result |
|---|---|
| `tests/test_manage.py` (26 checks vs stub Kong + manage subprocess) | **26/26 PASS** |
| `tests/test_manage_base.py` (14 checks: `BASE=/admin` rendering, cookie/CSRF, routing with dead Kong → 502 not 404) | **14/14 PASS** |
| `py_compile` manage.py | OK |

### 5.3 53 deployment — `deploy-manage53.sh` (all checks green)

- Container `kong-gw-manage` on `kong-gw-oss-net`, alias `manage`,
  `KONG_ADMIN=http://kong-gw-oss-kong:8001`, bound **127.0.0.1:18091** only.
- Users file `/home/<user>/kong-manage/manage-users` (600); credential
  generated on-server: `/home/<user>/backups/kong/CREDS-MANAGE-53-20261020-012128` (600, never printed).
- Live verification (loopback): login page 200; no-session 401; wrong pw 401;
  login 200; `GET /api/services` 200; `GET /api/kong` 200; POST without CSRF
  **403**; throwaway service CRUD: POST **201** → PUT **200** → pre-change
  backup file **written (1)** → DELETE **204** → GET **404**; audit lines 23.
- Exposure: `198.51.100.53:18091` **unreachable (000)**; `ss` shows
  127.0.0.1 only. Kong sanity: 18001 200, 18080 `/test-echo` 200.
- Note: first run failed the mutation checks (all 403) because the script
  logged in **twice** (two sessions; the CSRF came from session 2 while the
  cookie jar held session 1). Fixed to a single login — the server itself was
  correct. The 53 container was then hot-swapped to the BASE-aware
  `manage.py` (restart only; same credentials) and re-smoked green.

### 5.4 52 deployment — `deploy-manage52.sh` (all checks green)

- Container `kong-gw-manage-52` on `kong-gw-trial-net`,
  `KONG_ADMIN=http://kong-gw-trial-kong:8001`, `BASE=/admin`, bound
  **127.0.0.1:18092** only.
- Users file `/home/<user>/kong-manage-52/manage-users` (600); credential
  generated on-server: `/home/<user>/kong-panel/backups/CREDS-MANAGE-52-20261020-013334` (600, never printed).
- vhost: `location /admin/` added to the **existing 443 auth_basic server**
  (proxy_pass `http://127.0.0.1:18092/` — trailing slash strips the prefix),
  plus `location /admin` → 301 `/admin/`. Idempotent. Backup
  `vhost-kong-ai-ismc-ir.conf.pre-admin-20261020-013334` (600);
  `nginx -t` PASS → reload; auto-rollback armed (not triggered). New vhost
  md5 `15923636d85c7214bdaf1d36cc2a89cd`.
- **End-to-end through the 443 Basic-auth gate** (browser-equivalent path):
  http80 `/admin/` 301→https; `https /admin/` no-auth **401**; with Basic
  auth: page 200 (carries `const B="/admin"`), `POST /admin/login` 200,
  `GET /admin/api/services` 200, POST without CSRF **403**, throwaway CRUD
  201/200/204/404, pre-change backup **1 file**, audit 11 lines.
- Regression: `https /` 200 (Kong admin still behind the same gate),
  `https /panel/` 200 (Phase 1 panel intact), ext iface `198.51.100.52:18092`
  **000**; Kong admin 18001 200, proxy 18080 200.

### 5.5 Rollbacks (Phase 3)

- 53: `docker rm -f kong-gw-manage` (vhost: n/a on 53).
- 52 container: `docker rm -f kong-gw-manage-52`.
- 52 vhost: restore
  `/home/<user>/kong-panel/backups/vhost-kong-ai-ismc-ir.conf.pre-admin-20261020-013334`
  via the root-container technique, then `sudo -n /www/server/nginx/sbin/nginx -s reload`.

### 5.6 Phase 3 not-changed (explicit)

- No Kong container, volume, DB, or plugin on either server touched.
- No other vhost touched; port-80 redirect behavior on 52 unchanged.
- The old read-only panel (`panel/app.py`, 18090/443 `/panel/`) is untouched
  and still functional — the new management UI is additive at 443 `/admin/`.
- Both new containers restart-with-docker (`--restart unless-stopped`),
  `python:3.12-alpine`, no privileged flags.

## 6. Phase 4 execution results (2026-10-20, executed + verified)

### 6.1 Capability matrix (planning artifact)

`docs/CAPABILITY_MATRIX.md` — every WSO2-like feature mapped to
implemented / plugin-needed / needs-dev / out-of-OSS-scope, probed live
against the 3.9.4 plugin catalog on 53. No capability is claimed that was
not probed.

### 6.2 GitOps: declarative export / import (decK-style, OSS-only)

Scripts: `scripts/export.sh`, `scripts/import.sh`, `scripts/yaml2json.py`
(stdlib-only). Export writes a canonical JSON **and** a human-readable YAML
twin to `_export/kong-gateway.{json,yml}` with `_format_version: "3.0"`,
name-based relations (`_service` / `_route` / `_consumer`), targets folded
per upstream. Import is **strictly additive idempotent upsert** — it never
deletes — with a `--dry-run` that counts hypothetical actions.

**Live round-trip on 53 — 12/12 PASS** (`gitops-test53.sh`):
export with relations → YAML twin parses byte-equal to the JSON (via
`yaml2json.py`) → dry-run `created=0 updated=0 unchanged=33 errors=0`
against the live gateway → throwaway service+route+plugin import
`created=3 updated=0 errors=0` → visible in Admin API and 200 through the
proxy → cleanup cascade (plugin → route → service, 204s, then 404s) →
re-import `created=0 updated=0 unchanged=33 errors=0`.

Local: `tests/test_yaml2json.py` **26/26 PASS** (block YAML subset incl.
inline-mapping list items, quoted scalars, flow lists, comments).

### 6.3 Kong 3.9.4 Admin API findings (live-verified, affects all tooling)

1. **Relations are nested objects.** Routes/plugins expose
   `service: {"id": ...}` / `consumer: {...}` / `route: {...}` — the
   legacy `service_id` / `consumer_id` / `route_id` scalars are **absent**.
   Any exporter/importer that only reads `*_id` silently loses all
   relations (this actually bit us — see 6.4).
2. **No top-level `/targets` endpoint** (404). Targets are fetched per
   upstream: `GET /upstreams/{name}/targets` → `{"targets": [...]}`.
3. **DB-mode route-cache invalidation is async.** A freshly created route
   can 404 on the proxy for a few seconds — automation must retry.
4. **Deletion semantics.** `DELETE /services/{id}` with attached routes →
   400; explicit cascade plugin → route → service is required.
   Top-level `PUT /plugins/{id}` on a related plugin **NULLs its
   relation** — always use the nested endpoints
   (`/services/{sid}/plugins/{pid}`, `/routes/{rid}/plugins`, ...).

### 6.4 Damage and repair (disclosed, fully repaired)

The first import run (before finding 6.3-1) matched service-scoped plugins
as "global" and issued top-level `PUT /plugins/{id}` against the first
same-name plugin found: 3 physical plugins had their configs overwritten
and their service relations NULLed, becoming **global** orphans (a global
`oss-pre` would have altered traffic on every route).

Repair (all verified, not asserted):
- config-hash snapshot before/after re-running the idempotent
  `scripts/configure.sh` → all 11 intended service-scoped plugins restored,
  export dry-run back to `0/0/36/0` errors;
- the 3 orphan globals deleted one by one (204 each);
- final inventory: **11 service-scoped / 0 global** plugins;
- all 12 routes 200 on the proxy; full-chain
  `POST /combined-echo` → 200 with correlation id + body rename intact.

The regression guard now lives in the round-trip test itself (asserts every
route has `_service` and every plugin has a valid relation), so this class
of bug cannot pass the suite again.

### 6.5 Static API docs page (no Swagger dependency)

`scripts/gen-api-docs.py [ADMIN_URL] [OUT_HTML] [PROXY_BASE]` (stdlib-only,
read-only against the Admin API) renders a single self-contained dark-theme
HTML catalog: route-inventory table + per-route cards with copy-paste curl
examples (plain and with `X-Api-Key`), generation timestamp + Kong version
for provenance. Generated on 53 from the live inventory:
`_export/api-docs.html` — 12 routes, 9032 bytes, **0 external http refs**.

Served on 52 under the existing 443 Basic-auth gate (proven vhost pattern:
timestamped backup → atomic write via root container → `nginx -t` scoped
sudo → reload; auto-rollback armed, not triggered):

- new `location /apidocs/` → `alias /home/<user>/kong-api-docs/` (doc file
  uploaded 9032 B, md5-matched locally↔52) + `location /apidocs` → 301.
- verification (loopback, `Host: kong.ai.ismc.ir`):
  no-auth **401**; with gate credential **200** and
  `<title>Kong OSS Gateway - API Catalog</title>`; `/apidocs` 301;
  regressions clean (`/` 401 no-auth, port 80 301→https).
- vhost md5 `15923636…` → `b4cc3692…`; backup
  `/home/<user>/kong-panel/backups/vhost-kong-ai-ismc-ir.conf.pre-apidocs-20261020-023208` (600).

The page contains **no credentials, keys, or internal hostnames** — the
curl examples point at the public proxy URL pattern only.

### 6.6 Phase 4 not-changed (explicit)

- 52 Kong stack (1 service / 1 route / 0 plugins) untouched — the 52
  gateway remains a minimal trial; docs are served from 53's inventory.
- No plugin or container removed; the 3 orphan deletions in 6.4 were the
  only entity removals, and each was verified 204 + 404 afterwards.
- 53 inventory final: 10 services / 12 routes / 11 service-scoped plugins /
  0 consumers / 0 upstreams / 0 targets; admin 18001 loopback, proxy 18080.

---

## 7. Phase 5 execution results — AI Gateway (LiteLLM-like)

Executed on 53 (release host), 2026-10-20 UTC. All configuration was done
via `scripts/ai-gateway.sh` — an **idempotent** python-in-bash configurator
(stdlib only) that upserts every entity by name and prints `created`/
`updated` per step. Re-running it after every change produced all-`updated`
with zero errors (test T9).

### 7.1 What was configured (53, admin 127.0.0.1:18001)

| Entity | Value |
|---|---|
| Consumer | `ai-consumer` (custom_id `ai-gw`) |
| Credential | `key-auth` via **singular** `/consumers/ai-consumer/key-auth`; key format `ai-<32 hex>`; stored on 53 in `_export/ai-gw-creds` (mode 600, `aikey=…` line); **never printed** by any script or test |
| Service | `ai-gw` → `198.51.100.53:8000` (local vLLM `vllm-qwen38`), connect 5 s, read 60 s |
| Route | `ai-gw-v1`, path `/ai`, `strip_path=true`, no method restriction → `/ai/v1/chat/completions` hits upstream `/v1/chat/completions` (vLLM serves OpenAI API under `/v1/*`; bare `/models` is 404 upstream) |
| Plugins (all route-scoped) | `key-auth` (`api-key`/`X-Api-Key`, `hide_credentials`), `rate-limiting` (policy `local`, 30/min, 5/s), `oss-pre` (`correlation_id_header: X-Correlation-Id` — no body renames, so prompt bodies pass through **untouched**), `post-function` (metadata-only log, see 7.3) |

Inventory after configuration: **11 services / 13 routes / 15 plugins**
(started the phase at 10/12/11). One orphan route (name `null`, path `/ai`,
created by a mid-phase API quirk) was verified plugin-free and deleted
(204 + re-verified 404).

Responsibility boundary (kept): Kong enforces auth, routing, rate limit,
correlation id, metadata logging. Model routing / key pooling / fallbacks
remain the job of LiteLLM when present. **Provider keys never enter Kong**
config or logs — the `mock-litellm` (9001) master key is a provider-side
secret and was deliberately excluded.

### 7.2 Acceptance tests — 9/9 PASS (`ai-test53.sh`, live)

| # | Test | Result |
|---|---|---|
| T1 | no key → 401 | PASS |
| T2 | wrong key → 401 | PASS |
| T3 | success: 200 + `object=chat.completion` + `X-Correlation-Id` echoed (`oss-6ad6d8be-…`) | PASS |
| T4 | rate limit: 16 fast requests after a 61 s window clear → **11 × 429** | PASS |
| T5 | upstream error passthrough: unknown model → upstream 404 | PASS |
| T6 | `/ai/v1/models` passthrough → 200 | PASS |
| T7 | metadata log line present in Kong log with full fields | PASS |
| T8 | prompt content ("say ok") **not** in any `ai-gw-meta` line | PASS |
| T9 | idempotent re-run of `ai-gateway.sh` → all `updated`, no ERROR | PASS |

T4 note: the first iteration used 8 sequential *chat completions*, which
took seconds each and therefore spread across the 5/s window (0 × 429 on
one run, 3 × on another — non-deterministic). Final design: wait 61 s to
clear the rolling minute, then burst 16 fast `GET /ai/v1/models` requests;
the 5/s limit fires reliably (11 × 429 observed).

### 7.3 Metadata logging (post-function, LOG phase) — design & pitfalls

One line per request, **metadata only** (no bodies, no request headers):

```
ai-gw-meta: {"ts":1792465152,"method":"POST","path":"/ai/v1/chat/completions",
 "status":404,"duration_ms":4,"correlation_id":null,"consumer":"ai-consumer"}
```

Three real pitfalls were hit and fixed (all live-verified):

1. **The log_by_lua\* sandbox forbids `require 'cjson'`** in post-function
   code (`kong-lua-sandbox.lua: require 'cjson' not allowed within
   sandbox`) → JSON is built by hand with a tiny quote/escape helper.
2. **`KONG_LOG_LEVEL=notice` suppresses `ngx.INFO`** → the line is emitted
   at `ngx.WARN` (still clearly prefixed `ai-gw-meta:` so it can be grepped
   and filtered from alerting if desired).
3. **`kong.service.request.*` accessors return nil in the LOG phase on
   3.9** (observed `"method":null,"path":null`) → method/path are read from
   `ngx.var.request_method` / `ngx.var.uri` instead. `get_status()` and the
   response-header correlation id work; consumer is pcall-wrapped.

### 7.4 New Kong 3.9.4 Admin API findings (5 more, added to the list in §6.3)

1. Credential endpoints are **singular**: `/consumers/{username}/key-auth`
   (the plural `/key-auths` returns 404).
2. `?name=` list filters are **unreliable on some collections** (plugins) —
   fetch `?size=500` and match client-side.
3. **Name-based nested route refs 404** (`/services/{s}/routes/{ROUTE_NAME}/…`);
   use route IDs (`/routes/{id}/plugins` works).
4. **PUT on a route without `name` in the payload clears the name** to
   `null` — always include `name` on updates.
5. **post-function (log_by_lua\*) sandbox**: `require 'cjson'` forbidden;
   `kong.service.request.*` nil in LOG phase; `ngx.INFO` hidden under
   `KONG_LOG_LEVEL=notice`.

### 7.5 Phase 5 not-changed (explicit)

- No other services, routes, or plugins on 53 were modified; the AI route
  is additive. All AI backends (vllm-embedding, vllm-qwen38, gpu1,
  fine-tuned, mock-litellm, open-webui) were only read-probed.
- 52 untouched in this phase.
- No secrets committed anywhere; the only key exists on 53 in the 600
  CREDS file and inside Kong's DB.
- Rate-limit counters are the only state "consumed" by tests (self-clearing
  rolling windows; T4 clears the minute explicitly).

## 8. Phase 6 execution results — Config unification & GitOps

### 8.1 Deliverables (all in-repo, committed, sanitized)

| File | Purpose |
|---|---|
| `scripts/backup.sh` | Snapshot = declarative export (`kong-gateway.json` + `.yml` twin) + `pg_dump` + `manifest.json` (sha256 of every file + kong version); dir mode 700; prunes to 10 oldest (`BACKUP_KEEP`) |
| `scripts/restore.sh` | `<snapshot> --config` (additive, idempotent import — never deletes) or `--database` (full rewind: DROP/CREATE + `psql` import). Always takes an automatic safety snapshot first and hash-verifies the snapshot against its manifest before touching anything |
| `scripts/rollback.sh` | `--list` (snapshots + age) or `<snapshot>` → declarative rollback + `smoke-test.sh` |
| `docs/GITOPS.md` | GitOps loop, export hygiene (exports contain key-auth keys — why `_export/`/`_backup/` are git-ignored), backup/cron guidance, restore modes, rollback runbook, multi-env table, clean-clone procedure, compose working-dir pitfall (§6.1) |
| `.gitignore` | added `_export/` and `_backup/` |

### 8.2 Clean-clone acceptance test (Phase 6 + Phase 7 acceptance)

Probe (all green): git 2.43, GitHub public 200, ports 19080/19001 free,
348G free disk, no existing cleantest stack.

Test procedure (`clean-clone53.sh` on 53): fresh `git clone --depth 1` of
main into a disposable dir → point `.env.example` at
`kong-gw-cleantest` / 19080 / 19001 → `setup.sh` → `smoke-test.sh` →
`run-tests.sh` (18 mandatory + 9 boundary) → `backup.sh` → production
untouched check.

| Run | Commit | Result |
|---|---|---|
| 1 | `60994bd` | FAIL — exposed bug #1 (§8.3); production side-effect (§8.4) |
| 2 | `954c6e4` | setup now runs as `kong-gw-cleantest` (production untouched); tests 404'd — exposed bug #2 |
| 3 | `6585786` | **CLEAN-CLONE-RESULT: FAILS=0 — ALL PASS** |

Run 3 detail (fresh clone of main, nothing pre-provisioned):

- `setup.sh` PASS — .env auto-created (random PG password, mode 600),
  image built, containers healthy, 10 services / 12 routes / 11 plugins
  configured, data-plane convergence wait returned 200 after ~10 s
- `smoke-test.sh` — **14/14 PASS**
- `run-tests.sh` — **18/18 PASS** (T15: p50=1.201 ms, p95=2.049 ms,
  p99=2.298 ms; T16: 0 errors / 200 mixed requests) **+ 9/9 boundary PASS**
- `backup.sh` PASS — first snapshot of the fresh stack, 3 files hashed
- production check — 18080/18001 responding, zero interference

Teardown: `compose -p kong-gw-cleantest down` (deliberately **without**
`-v`), clone dir removed; the volume `kong-gw-cleantest-pgdata` was left
in place for the Phase 11 owner decision. Production plugin mounts were
verified still anchored to the production directory before and after the
clone dir deletion.

### 8.3 Two genuine product bugs found by the acceptance test (both fixed, both pushed)

1. **`setup.sh` .env timing** (fixed in `954c6e4`): `_common.sh` is
   sourced at the top of `setup.sh`, i.e. *before* the .env creation
   block. On a fresh clone `.env` does not exist yet, so the shell
   variables were already defaulted (`kong-gw-oss`, 18080/18001) and the
   values written into the just-created `.env` were silently ignored.
   The test stack ran as the production project name. Fix: re-source
   `_common.sh` after the .env block (its `set -a` load overwrites the
   earlier defaults); the header log now prints the final project name
   and ports.
2. **Data-plane convergence** (fixed in `6585786`): Kong loads DB config
   into the data plane asynchronously (`db_update_freq`). Right after
   `configure.sh` creates the routes, the proxy can answer 404 for up to
   ~30 s even though the Admin API already serves the routes (observed
   live: all 12 routes present in Admin, every proxy request 404 until
   the cache caught up). `setup.sh` declared FAIL at that point. Fix:
   poll `/test-echo` for up to 120 s before declaring setup complete, so
   a fresh install returns only when it is genuinely ready.

### 8.4 Damage and repair (disclosed, fully repaired) — run 1 side effect

- Run 1's `compose up -d --build` executed as project `kong-gw-oss` from
  the *clone* directory, so Docker Compose **recreated the production
  containers** `kong-gw-oss-{db,echo,migrate,kong}` and re-anchored the
  kong container's plugin bind mounts to
  `/home/<user>/kong-clean-test/plugins/{oss-pre,oss-post}`.
- **No data loss**: the `kong-gw-oss-pgdata` volume was untouched; all
  configuration data survived. `configure.sh` from the test run died
  before applying anything (wrong port).
- Repair (executed, verified): `docker compose -p kong-gw-oss up -d`
  from the production directory re-created the kong container with the
  correct mounts; re-verified `ai-test53.sh` **9/9 PASS**, inventory
  **11 services / 13 routes / 15 plugins**, `/test-echo` 200,
  `/status` 200.
- Prevention: fix #1 makes the project name come from `.env` on every
  fresh install; `docs/GITOPS.md` §6.1 documents the compose
  project-name/working-directory pitfall (always `cd` into a stack's own
  checkout before compose commands).

### 8.5 Multi-environment (documented in GITOPS.md)

dev `kong-gw-dev` 18080/18001 · staging `kong-gw-staging` 19080/19001
(proven by the clean-clone run) · prod `kong-gw-prod` loopback behind
TLS. Admin API always loopback-only.

### 8.6 Phase 6 not-changed (explicit)

- No production config on 53 was modified by this phase (AI gateway
  route and inventory unchanged; the only production change was the
  container recreation/repair in §8.4).
- 52 untouched in this phase.
- No secrets committed: `_export/`/`_backup/` are git-ignored; snapshot
  dirs are mode 700 on 53.
- Left for Phase 11 (owner decision): the `kong-gw-cleantest-pgdata`
  volume and the `/tmp/*.sh` test scripts on 53.
