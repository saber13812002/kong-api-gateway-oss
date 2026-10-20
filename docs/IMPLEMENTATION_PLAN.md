# IMPLEMENTATION PLAN — Kong OSS Enterprise API + AI Gateway

**Date:** 2026-10-19 · **Companion to:** [PROJECT_AUDIT.md](PROJECT_AUDIT.md)

## Goals & acceptance

Turn the existing Kong OSS 3.9.4 deployment into a deliverable, documented,
tested organizational **API Gateway** with a defined **AI Gateway** path,
canonical GitHub `main`, real management UI, and a training course. A phase is
*done* only when its acceptance checks are executed and recorded — never
assumed from prior reports.

---

## Phase 1 — Fix the panel exposure (52) — URGENT — ✅ **DONE (2026-10-19)**

**Result:** vhost fixed in-place via root-container technique (backup +
`nginx -t` + auto-rollback). Public verification: HTTP `/panel/` → 301 with
no data leak; HTTPS `/panel/` → 401 no-auth / 401 wrong / 200 correct
(through the real 443 vhost); ACME path intact; 3 other domains
unaffected. Full matrix: [PROJECT_AUDIT.md §4.1](PROJECT_AUDIT.md).

**Problem (D1/D2):** `http://kong.ai.ismc.ir/panel/` returns the full panel
without authentication; the HTTPS path doesn't route to the panel at all.

**Constraints:** editing `/www/server/panel/vhost/nginx/kong.ai.ismc.ir.conf`
requires root. Scoped sudo on 52 covers `nginx`/`systemctl`/`ss`/`journalctl`/
`chmod` only — **not** file writers. So the fix is executed in two layers:

1. **Immediate mitigation (no root needed):** make the panel app itself
   require a shared secret (env-injected, file-backed on 52, mode 600) for
   `/panel/api/*`; keep the HTML shell. Result: HTTP port-80 `/panel/` can no
   longer leak live data or logs. Restart `kong-gw-panel` (docker, no sudo).
   - Acceptance: `curl http://kong.ai.ismc.ir/panel/api/status` → 401/403;
     with secret → 200; HTML shell may load but carries no data.
2. **Permanent vhost fix (owner-run, root):** staged file
   `ops/52-fix/fix-panel-vhost.sh` + staged vhost:
   - port-80 block: `location /panel/ { return 301 https://$host/panel/; }`
     (drop the unauthenticated proxy; keep ACME + generic redirect)
   - port-443 block (behind existing `auth_basic`): add
     `location /panel/ { proxy_pass http://127.0.0.1:18090/; … }`
   - script: backup current vhost (timestamped), atomic replace,
     `sudo nginx -t`, reload on pass, auto-rollback on fail.
   - Owner runs: `sudo bash /home/<user>/ops/52-fix/fix-panel-vhost.sh`
   - Acceptance matrix (public): 80 `/panel/` → 301 to https; 80 `/` → 301
     https; 443 no-auth → 401; 443 wrong → 401; 443 good → 200 panel;
     443 `/status` no-auth → 401 (Kong API unchanged); other vhosts
     unaffected (spot-check 2 domains).
3. **Rollback:** restore the timestamped vhost + `nginx -t` + reload;
   app-level mitigation can be re-disabled by removing the secret env.

**Do not** stop/reload anything on 53 in this phase. **Do not** touch other
vhosts, BaoTa panel service, or the GitLab container.

## Phase 2 — Recover admin access (controlled) — ✅ **DONE (2026-10-20)**

**Result:** all three gates now have working `$6$`-hashed credentials
(generated on-server, stored only in mode-600 CREDS files, never printed):
52 443 → `CREDS-20261019-235512`; 53 18002 → `CREDS-20261020-000800`;
52 8001 → `CREDS-8001-20261020-005225`. Both LAN proxies restricted to
loopback (external-iface curls return 000); rollbacks documented.
One credential was accidentally exposed in diagnostic output and was
rotated (old value verified 401). Learned rule: htpasswd must be **644**
on 52 (non-root nginx workers; 600 breaks authenticated requests with
`[crit] Permission denied`). Details: [PROJECT_AUDIT.md §4.2–4.4](PROJECT_AUDIT.md).

**Owner decisions still open:** remove-vs-keep the loopback proxies;
confirm no LAN tooling needs 8001/18002; rotate CREDS passwords to
owner-chosen values via secure channel.

**Original plan:**

1. Keep all three auth gates (52 vhost, 52:8001, 53:18002) **intact**; they
   are the only gate between the network and the unauthenticated Kong Admin.
2. **53 (self-service, owner-supplied secret):** new `htpasswd` entry
   `admin:<owner-chosen>` generated **on-server** (`htpasswd -B`/`-b` from a
   stdin value that is piped and never echoed), replace file atomically
   (backup first), reload `kong-admin-auth`. Owner obtains the password via a
   secure channel and it is never written to chat/repo/logs.
3. **52 (owner-run, root):** same replacement of
   `/etc/nginx-htpasswd-kong` (single atomic root session; also `chmod 600`
   it — fixes D5) + BaoTa vhost chmod-quirk handling in the same session.
4. After each: run the full auth matrix (no/wrong/good) on every path and
   record results.
5. **8001 decision:** evidence shows only 2 client IPs and no monitoring
   dependency. Plan: after Phase 2 verification, restrict
   `kong-admin-auth-52` to `127.0.0.1:8001` (edit its listen directive +
   recreate container; backup first) — **with owner confirmation** at the
   decision point. 53's 18002: same plan (loopback-only) unless owner states
   a LAN consumer.
6. **Do not** delete either proxy without explicit owner approval;
   **do not** expose Admin API on any new interface.

## Phase 3 — Real management UI (Kong OSS) — ✅ DONE (2026-10-20)

**Result (executed + verified):** new stdlib-only service
`panel/manage.py` (sessions + per-session CSRF + real RBAC
viewer/operator/admin + JSONL audit + pre-change 600 backups + nonce CSP +
login rate-limit + `BASE` prefix support) deployed as
`kong-gw-manage` on 53 (127.0.0.1:18091) and `kong-gw-manage-52` on 52
(127.0.0.1:18092, exposed **only** via the 443 auth_basic gate at
`https://kong.ai.ismc.ir/admin/`). Browser never reaches the Admin API on
either server. Tests: 26/26 + 14/14 local suites PASS; live throwaway
service CRUD (201/200/204/404) + backup + audit verified on **both**
servers end-to-end through the real 443 gate on 52; external interfaces
000; no regression to `/` (Kong), `/panel/`, port 80, or any other vhost.
Credentials in 600 CREDS files on-server (paths in
`PROJECT_AUDIT.md` §5.3/§5.4), never printed. Rollbacks in §5.5.
Full detail: `PROJECT_AUDIT.md` §5.

**Original plan (as written):**

- Extend the existing panel into a management UI behind the **443 auth
  gate only** (D1/D2 fixed first). Architecture:
  `browser → https vhost (Basic auth) → panel backend (127.0.0.1:18090) →
  Kong Admin (docker-internal :8001)`. Browser never touches Admin API.
- Backend: stdlib Python (already in use) → small JSON API with:
  read endpoints (services/routes/consumers/plugins/upstreams + health),
  write endpoints guarded by a **second, app-level RBAC token** (roles:
  viewer/operator/admin), input validation (schema-checked against Kong
  Admin expectations), **audit log** (user, ts, op, result; never secrets),
  CSRF token + SameSite cookies, `Content-Security-Policy` headers,
  confirm-dialogs on destructive ops, pre-change export of the object being
  modified (rollback aid).
- OSS reality check (documented, not hidden): Kong OSS 3.9 has
  `request-transformer`, `response-transformer`, `cors`, `http-log`,
  `file-log`, `rate-limiting` (single-node only), `key-auth`, `hmac-auth`,
  `jwt`, `basic-auth`, `session`, `acl`, `oauth2`, `ip-restriction`,
  `request-size-limiting`, etc. **No** developer portal, no enterprise
  plugins (response-ratelimiting, correlation-id enterprise, etc.) — those
  are marked "out of OSS scope" or implemented via our custom plugins.
- Enablement order: read-only first (tested) → then write endpoints
  (each independently tested) → UI polish.

## Phase 4 — Organizational API Gateway (WSO2-like scope) ✅ DONE

**Result (2026-10-20, executed + verified — see `docs/PROJECT_AUDIT.md` §6):**
capability matrix delivered (`docs/CAPABILITY_MATRIX.md`); GitOps
export/import live round-trip on 53 **12/12 PASS** with a byte-equal YAML
twin; Kong 3.9.4 Admin-API findings documented (nested relation objects,
no top-level `/targets`, async route-cache invalidation, DELETE cascade,
nested-endpoint PUTs only); one intermediate import bug clobbered 3
plugins — **repaired and verified** (11 service-scoped / 0 global; all
routes 200; full chain 200); static API-docs page generated from the live
inventory and served on 52 behind the 443 auth gate at `/apidocs/`
(401 no-auth / 200 with-auth verified, regressions clean).

Deliver a **capability matrix** (implemented / plugin-needed / needs dev /
out of OSS scope) and implement the OSS-doable set:
- Service+Route CRUD (UI), Upstream+Target management (OSS has Upstreams;
  active health checks are Enterprise → documented as limitation).
- Auth: `key-auth`/`hmac-auth`/`jwt`/`basic-auth` + our `oss-pre` gate.
- Rate limiting: OSS `rate-limiting` (single-DB-node semantics — documented).
- Header/body transformation (bundled + custom plugins), request-size
  limiting, correlation id (oss-pre), http-log/file-log for observability,
  versioning pattern via route naming (`/v1/...`), export/import of all
  config to Git (decK-style declarative file produced by `scripts/export.sh`).
- OpenAPI doc page: static, generated from route inventory (no Swagger UI
  dependency); API try-out via curl examples.

## Phase 5 — AI Gateway (LiteLLM-like) ✅ DONE

**Result (2026-10-20, executed on 53):** idempotent `scripts/ai-gateway.sh`
configured consumer `ai-consumer` + key-auth credential (600 CREDS file, key
never printed), service `ai-gw` → `198.51.100.53:8000` (vLLM qwen3.8), route
`ai-gw-v1` (`/ai`, strip_path), and 4 route-scoped plugins (key-auth,
rate-limiting 30/min + 5/s local, oss-pre correlation id, post-function
metadata-only log). Live test suite `ai-test53.sh`: **9/9 PASS** — auth
rejects (401 ×2), real LLM completion (200 + `chat.completion` +
X-Correlation-Id echoed), rate limiting (11 × 429 in a 16-request burst),
upstream 404 passthrough, `/ai/v1/models` 200, metadata log present with
**no prompt content** in any line, idempotent re-run all-`updated`.
Inventory: 11 services / 13 routes / 15 plugins; provider keys never in
Kong. 5 new Kong 3.9.4 Admin API findings recorded (see PROJECT_AUDIT.md
§7.4–7.5). Details: PROJECT_AUDIT.md §7.

- Reference targets already on 53 (OpenAI-compatible): `vllm-embedding`
  (host 4000), `vllm-qwen38` (8000), `vllm-qwen38-gpu1` (8001),
  fine-tuned (8101), `mock-litellm` (9001), `open-webui` (80).
- Build on 53 (release host):
  - Kong service `ai-gw` → route `/ai/v1/*` (host-level ports are LAN-only
    on 53; no public vhost exists there — documented).
  - Upstream → chosen OpenAI-compatible endpoint (default: the local
    vLLM on 8000 for real LLM traffic; mock-litellm for non-destructive
    CI).
  - `key-auth` on the route + `rate-limiting` + `oss-pre` correlation id +
    `http-log`/`file-log` metadata (status, duration, request-id; **prompt
    bodies are NOT logged**).
  - Tests: success, auth reject, rate-limit reject, upstream timeout/error,
    Open WebUI/LiteLLM client attach docs.
- Responsibility boundary (documented): Kong enforces auth, routing,
  rate-limit, metadata; model routing/key-pooling/fallbacks belong to
  LiteLLM when present. Provider keys stay in the AI tier, never in Kong
  config or logs.

## Phase 6 — Config unification & GitOps ✅ DONE

**Result (2026-10-20, executed on 53):** `backup.sh` (declarative export +
pg_dump + sha256 manifest, mode 700, prune 10), `restore.sh`
(`--config` additive / `--database` full rewind; auto safety snapshot +
hash verify), `rollback.sh` (`--list` + declarative rollback + smoke),
`docs/GITOPS.md` (loop, hygiene, runbook, multi-env, clean-clone,
compose working-dir pitfall), `.gitignore` covers `_export/`/`_backup/`.
Clean-clone acceptance on 53 from GitHub main (disposable project
`kong-gw-cleantest` on 19080/19001): **ALL PASS** — setup + 14/14 smoke +
18/18 tests + 9/9 boundary + first backup; production verified untouched.
The acceptance run exposed and fixed two genuine product bugs:
(1) `setup.sh` sourced `_common.sh` before creating `.env`, so a fresh
install silently ignored the .env project name/ports (commit `954c6e4`);
(2) data-plane config convergence — proxy 404s up to ~30 s after route
creation (commit `6585786` adds a 120 s convergence wait). Run 1's
production side effect (container recreation from the clone dir) was
disclosed, repaired, and re-verified (AI tests 9/9, inventory
11/13/15). Details: PROJECT_AUDIT.md §8.

## Phase 7 — GitHub canonicalization ✅ DONE

**Result (2026-10-20):** the `release/` tree was verified to strictly
supersede the root git checkout (content-identical except CRLF + one
encoding-fixed file) and folded into the root checkout. Sanitization
scan (45 hits: 13 internal IPs, 30 personal paths, 2 documented
test-fixture creds) neutralized: LAN IPs → TEST-NET-2 `198.51.100.x`,
personal paths → `/home/<user>`, AI backend default → 127.0.0.1, fixture
creds commented. `yaml2json` re-verified 26/26. Commits pushed to the
public GitHub `main` (see the repo URL in the clone script) with normal
pushes,
no force, no rewrite: `633cee4` → `7da0751` → `6291466` → `60994bd`
→ `954c6e4` (setup.sh .env fix) → `6585786` (data-plane convergence
fix) → docs commit. `release/` remains a scratch mirror only.
Clean-clone install from the new main: **ALL PASS** (doubles as the
Phase 6 acceptance — see §8). GitLab: no mirror exists; GitHub is the
sole canonical (documented; mirror recreation is an owner option).

## Phase 8 — Deliverable README ✅ DONE

**Result (2026-10-20):** `README.md` fully rewritten to the mandatory
24-section structure (commit `d99891d`, pushed to `main`): 1 Overview,
2 capability matrix (tagged, OSS gaps explicit), 3 Architecture, 4
Prerequisites, 5 Quick start, 6 Configuration, 7 Repository layout, 8
Routes, 9 Custom plugins, 10 Management UI, 11 AI gateway, 12 Static API
docs, 13 GitOps scripts, 14 Testing, 15 Security posture, 16 Benchmark,
17 Logs, 18 Operations/multi-env, 19 Troubleshooting, 20 OSS
limitations, 21 nine Admin API pitfalls, 22 Documentation & training map,
23 AI-agent workflow, 24 Verification status & re-verify procedure.
**Every command in it is executed during Phase 10**; untested commands
are labeled, not claimed. Host-specific references (52/53) are labeled
as such. Sanitization scan clean; LF line endings verified; mirrored to
`release/` (scratch only).

## Phase 9 — Training course ✅ DONE

**Result (2026-10-20):** `docs/training/` created — index + 8 sessions:
01 Architecture & first install, 02 Services & routes (Admin API),
03 Plugins (custom & bundled), 04 Authentication & security,
05 Management UI, 06 AI gateway, 07 GitOps (export/import/backup/
restore), 08 Operations (multi-env, load, troubleshooting). Each session
has objectives, prerequisites, instructor script, a non-destructive
hands-on lab (`train-` prefixed throwaway objects, `/test-echo` target,
explicit cleanup steps), expected output, quiz, and a common-errors
table. All commands reference real scripts in the repo. LF-verified,
sanitization scan clean.

## Phase 10 — Acceptance test suite (recorded)

Run and record (command / expected / actual / PASS-FAIL):
install-from-clone; health+DB; UI CRUD; auth matrix (all paths);
rate-limit; unauthorized access; size limits; request/response
transformation; correlation id; light load; restart-recovery; TLS+auth;
Admin API network-exposure check; backup/restore round-trip; UI/backend
security checks; AI gateway integration; every README command.
Re-run benchmark (do not cite old numbers).

## Phase 11 — Cleanup & handover (owner-gated)

Per-server inventory → classify in-use / shared / deletable. Nothing shared
deleted. 53 final stack untouched without owner sign-off. 52 trial stack,
volumes, images, old folders: deletable **only with explicit owner
confirmation**. Final report: freed space, remaining resources,
owner decisions needed.

---

## Execution order & independence

| Order | Phase | Blocked by | Notes |
|---|---|---|---|
| 1 | 1 (panel fix) | — | start immediately; mitigation is root-free |
| 2 | 2 (admin auth) | 1 (panel uses same htpasswd on 52) | needs owner's new secret |
| 3 | 3 (UI) | 1 | read-only first |
| 4 | 4 (API GW features) | 3 | mostly config/UI |
| 5 | 5 (AI GW) | 3 | on 53, non-destructive |
| 6 | 6 (GitOps) | 3,4 | scripts in repo |
| 7 | 7 (GitHub) | 0,6,8-partial | push after docs land |
| 8 | 8 (README) | 3,4,5,6 | commands verified in 10 |
| 9 | 9 (training) | 3,4,5 | docs |
| 10 | 10 (acceptance) | 1–9 | records everything |
| 11 | 11 (cleanup) | 10 + owner | gated |

## Non-negotiables (per mission)

- No secret ever printed/committed; owner secrets only via on-server files.
- No force push, no history rewrite, no repo/branch deletion.
- No deletion of shared images/volumes/containers.
- Backup + rollback before any live change.
- Read-only panel is not a "full admin UI" until Phase 3 lands.
- OSS limitations documented, not hidden.
