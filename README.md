# Kong OSS — Organizational API & AI Gateway (Standalone Release)

A complete, self-contained [Kong Gateway OSS 3.9.4](https://kong.org/kong-gateway/)
deployment: API gateway + AI gateway + management UI + GitOps tooling, all
in Docker Compose, with two hardened custom Lua plugins, a deterministic
test backend, an automated test suite, a benchmark, and full documentation.

> **📖 Start here → [docs/INSTALL.md](docs/INSTALL.md)**

**Status (recorded, 2026-10-20):** clean-clone install from GitHub `main`
on the release host — **18/18 mandatory + 9/9 boundary tests PASS, 14/14
smoke, AI gateway 9/9**, production stack verified untouched. Every
command in this file has been executed at least once during this project;
the final acceptance re-run is recorded in [docs/PROJECT_AUDIT.md](docs/PROJECT_AUDIT.md).
Sections that reference host-specific wiring (52/53) are labeled as such.

---

## Contents

1. [Overview](#1-overview)
2. [What is supported (capability matrix)](#2-what-is-supported-capability-matrix)
3. [Architecture](#3-architecture)
4. [Prerequisites](#4-prerequisites)
5. [Quick start (install)](#5-quick-start-install)
6. [Configuration (.env)](#6-configuration-env)
7. [Repository layout](#7-repository-layout)
8. [Routes & demo capabilities](#8-routes--demo-capabilities)
9. [Custom plugins (oss-pre / oss-post)](#9-custom-plugins-oss-pre--oss-post)
10. [Management UI](#10-management-ui)
11. [AI gateway (LiteLLM-like)](#11-ai-gateway-litellm-like)
12. [Static API docs page](#12-static-api-docs-page)
13. [GitOps: export / import / backup / restore / rollback](#13-gitops-export--import--backup--restore--rollback)
14. [Testing](#14-testing)
15. [Security posture](#15-security-posture)
16. [Performance (benchmark)](#16-performance-benchmark)
17. [Logs & observability](#17-logs--observability)
18. [Operations: restarts, upgrades, multi-env](#18-operations-restarts-upgrades-multi-env)
19. [Troubleshooting](#19-troubleshooting)
20. [OSS limitations & honest gaps](#20-oss-limitations--honest-gaps)
21. [Kong 3.9.4 Admin API findings (pitfall list)](#21-kong-394-admin-api-findings-pitfall-list)
22. [Documentation & training map](#22-documentation--training-map)
23. [AI-agent workflow](#23-ai-agent-workflow)
24. [Verification status & how to re-verify](#24-verification-status--how-to-re-verify)

---

## 1. Overview

| Aspect | Value |
|---|---|
| Gateway | Kong Gateway **3.9.4 OSS**, DB mode (PostgreSQL 16.6-alpine) |
| Custom plugins | `oss-pre` (request pre-processing), `oss-post` (response post-processing) |
| Management | Web UI (`panel/manage.py`, stdlib Python, no deps) + full Admin API scripts |
| AI gateway | `ai-gw` route → any OpenAI-compatible backend (verified against vLLM) |
| GitOps | declarative export/import, snapshots (export + pg_dump + sha256 manifest), restore, rollback |
| Testing | 18 mandatory + 9 security-boundary + management-UI + yaml2json suites |
| Footprint | 1 compose file, 4 containers, loopback-only host ports, ~1 GB disk |

The stack is fully namespaced by `COMPOSE_PROJECT_NAME` so several stacks
can coexist on one host (verified: production + a clean-clone test stack
ran side by side).

## 2. What is supported (capability matrix)

Full tagged matrix: [docs/CAPABILITY_MATRIX.md](docs/CAPABILITY_MATRIX.md).
Summary:

| Capability | Status |
|---|---|
| Routing, load balancing (upstreams/targets), health checks | ✅ bundled Kong |
| Rate limiting (local policy) | ✅ used on AI route: 30/min + 5/s |
| API key auth (real key validation) | ✅ `key-auth` (AI route) |
| Header-presence auth gate (demo) | ✅ `oss-pre` (controlled 400 JSON) |
| Request/response transform (bundled) | ✅ `request-transformer` / `response-transformer` |
| JSON body key renames (req + resp) | ✅ custom `oss-pre` / `oss-post` |
| Correlation IDs end-to-end | ✅ `oss-pre` generates `oss-…`, echoes back |
| AI proxying (OpenAI-compatible) | ✅ verified vs vLLM (completions + /models) |
| AI metadata logging (no prompts) | ✅ post-function, WARN-level JSON |
| Provider key pooling / model failover | ❌ LiteLLM-tier responsibility (documented boundary) |
| TLS termination | ❌ OSS gap — front with nginx/ALB (52 does this) |
| WAF | ❌ not included |
| Management UI | ✅ roles (admin/viewer), audit log, per-entity backup |
| GitOps export/import/backup/restore/rollback | ✅ scripts in `scripts/` |
| Declarative mode | ⚠️ OSS 3.9 has no declarative DB backend; tooling is Admin-API based (documented) |

## 3. Architecture

```
                 internal network: <project>-net  (no internet exposure)
+--------------------------------------------------------------------------+
| client                                                                    |
|   │  http://127.0.0.1:18080  (Proxy — loopback only)                      |
|   ▼                                                                       |
| kong (kong:3.9.4, OSS)                                                    |
|   ├─ Admin API   http://127.0.0.1:18001  (loopback only)                  |
|   ├─ plugins: bundled + oss-pre + oss-post  (read-only bind mounts)       |
|   ├─ PostgreSQL:  <project>-db (postgres:16.6-alpine, NO host ports)      |
|   │             volume: <project>-pgdata                                  |
|   └─► echo:9000  deterministic test backend (no host ports)               |
|                                                                           |
| migrate: one-shot `kong migrations up` (bootstrap), kong waits for it     |
+--------------------------------------------------------------------------+
```

- **Fully isolated**: every container/volume/network is prefixed with
  `COMPOSE_PROJECT_NAME` (default `kong-gw-oss`).
- **Only loopback host ports** are published (18080 proxy, 18001 admin).
  PostgreSQL and the echo backend have no host ports at all.
- **Env-driven**: everything tunable lives in `.env`
  ([docs/CONFIGURATION.md](docs/CONFIGURATION.md)).

**Production reference deployment (host 52, labeled):** nginx vhost
`ai.ismc.ir` terminates TLS on 443, proxies `/kong/` → 18080,
`/admin/` → management UI, `/apidocs/` → generated static API docs.
That vhost is server-specific configuration, not part of this repo.

## 4. Prerequisites

- Linux (or Docker Desktop) with **Docker Engine ≥ 24** and
  **Docker Compose v2**
- `curl` and `python3` (standard library only — no pip installs)
- ~1 GB free disk; free loopback ports 18080 + 18001 (changeable in `.env`)

```bash
docker version && docker compose version
```

## 5. Quick start (install)

All commands are run from the repository root.

```bash
# 0) get the code
git clone <repo-url> kong-api-gateway-oss
cd kong-api-gateway-oss

# 1) one-shot: creates .env (auto password, mode 600), builds,
#    starts, waits healthy, configures (idempotent), waits for the
#    data plane to serve the new routes
bash scripts/setup.sh

# 2) verify
bash scripts/smoke-test.sh          # 14 fast e2e checks
bash scripts/run-tests.sh           # 18 mandatory + 9 boundary
```

> `setup.sh` declares success only after `GET /test-echo` through the
> proxy returns 200 (data-plane convergence wait, up to 120 s).

Manual equivalent (if you prefer each step):

```bash
cp .env.example .env
sed -i 's/^KONG_PG_PASSWORD=.*/KONG_PG_PASSWORD='$(openssl rand -hex 24)'/' .env
chmod 600 .env
docker compose config -q && docker compose up -d --build
docker compose ps                     # wait until db + kong are healthy
bash scripts/configure.sh             # idempotent: 10 services, 12 routes, 11 plugins
bash scripts/smoke-test.sh
```

### Try the demo endpoints

```bash
# baseline echo through Kong
curl -s "http://127.0.0.1:18080/test-echo?name=hi"

# authenticated route — WITH the key (200):
curl -s -X POST http://127.0.0.1:18080/secure-echo \
     -H 'Content-Type: application/json' -H 'X-Api-Key: my-key' \
     -d '{"hello":"world"}'

# authenticated route — WITHOUT the key (400 controlled JSON):
curl -si -X POST http://127.0.0.1:18080/secure-echo \
     -H 'Content-Type: application/json' -d '{"hello":"world"}'

# request body rename: customer_id -> customerId (seen by the upstream)
curl -s -X POST http://127.0.0.1:18080/t-pre \
     -H 'Content-Type: application/json' -H 'X-Api-Key: k' \
     -d '{"customer_id":42}'

# response JSON transform: {"status":...} -> {"success":...} + X-Oss-Post
curl -si http://127.0.0.1:18080/fixed-ok

# full chain: auth + correlation id + request rename + response rename
curl -si -X POST http://127.0.0.1:18080/combined-echo \
     -H 'Content-Type: application/json' -H 'X-Api-Key: k' \
     -H 'X-Correlation-Id: demo-1' \
     -d '{"customer_id":7}'
```

## 6. Configuration (.env)

`.env` is git-ignored; `.env.example` is the template.

| Variable | Default | Meaning |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | `kong-gw-oss` | namespaces ALL containers/volumes/networks |
| `KONG_VERSION` | `3.9.4` | pinned Kong image |
| `POSTGRES_VERSION` | `16.6-alpine` | pinned Postgres image |
| `KONG_PG_PASSWORD` | — (auto-generated by setup.sh) | internal PG password; **mode 600** |
| `KONG_PROXY_HOST` / `KONG_PROXY_PORT` | `127.0.0.1` / `18080` | proxy binding (keep loopback) |
| `KONG_ADMIN_HOST` / `KONG_ADMIN_PORT` | `127.0.0.1` / `18001` | admin binding (keep loopback) |
| `ECHO_BACKEND_NAME` | `oss-echo` | cosmetic, used in tests |

**Gotcha (fixed in this release):** `setup.sh` re-sources its env after
creating `.env`, so a fresh install always honors the `.env` project
name/ports. If you run `docker compose` manually, always `cd` into the
stack's own checkout — compose anchors relative bind mounts to the
working directory and namespaces by project name
([docs/GITOPS.md §6.1](docs/GITOPS.md#61-running-a-second-stack-side-by-side-pitfall)).

All runtime routing/config is applied idempotently via the Admin API
(`scripts/configure.sh`) — there is no declarative file to keep in sync.
Full reference: [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## 7. Repository layout

```
├── docker-compose.yml       # the whole stack (env-driven)
├── .env.example             # template — copy to .env
├── .gitignore               # .env, _export/, _backup/, results/
├── AGENT_HANDOFF.md         # handover snapshot for operators/agents
├── plugins/
│   ├── oss-pre/             # request pre-processing plugin
│   └── oss-post/            # response post-processing plugin
├── echo/                    # deterministic test backend (stdlib Python)
├── bench/                   # benchmark client (stdlib Python)
├── panel/
│   └── manage.py            # management UI (stdlib Python, no deps)
├── scripts/
│   ├── setup.sh             # one-shot install (env + start + configure + wait)
│   ├── configure.sh         # idempotent Admin API configuration (12 routes)
│   ├── smoke-test.sh        # 14 fast e2e checks
│   ├── run-tests.sh         # 18 mandatory + 9 boundary tests
│   ├── security-test.sh     # 11 security posture checks
│   ├── restart-test.sh      # kong restart + stability fingerprint
│   ├── benchmark.sh         # direct-vs-Kong latency benchmark
│   ├── export.sh            # GitOps: live config -> kong-gateway.json/.yml
│   ├── import.sh            # GitOps: declarative file -> live (additive)
│   ├── backup.sh            # snapshot: export + pg_dump + sha256 manifest
│   ├── restore.sh           # snapshot -> live (--config | --database)
│   ├── rollback.sh          # --list | declarative rollback + smoke
│   ├── gen-api-docs.py      # generate static API docs HTML from live config
│   ├── yaml2json.py         # dependency-free YAML->JSON (import fallback)
│   ├── ai-gateway.sh        # idempotent AI gateway configuration (53)
│   └── _common.sh           # shared helpers (env, compose, waits)
├── tests/
│   ├── test_suite.py        # T01–T18 (mandatory)
│   ├── boundary.py          # B1–B9 (security boundary)
│   ├── test_manage.py       # management UI API tests (live 53/52)
│   ├── test_manage_base.py  # management UI tests vs throwaway instance
│   └── test_yaml2json.py    # yaml2json conformance (26 fixtures)
├── _export/                 # GitOps exports (git-ignored: contains keys!)
├── _backup/                 # snapshots (git-ignored, mode 700)
└── docs/
    ├── INSTALL.md           # ← start here
    ├── CONFIGURATION.md
    ├── SECURITY.md
    ├── TESTING.md
    ├── TROUBLESHOOTING.md
    ├── GITOPS.md            # loop, runbooks, multi-env, clean-clone
    ├── CAPABILITY_MATRIX.md
    ├── PROJECT_AUDIT.md     # execution record (all phases, real output)
    └── IMPLEMENTATION_PLAN.md
```

## 8. Routes & demo capabilities

Created by `scripts/configure.sh` (idempotent):

| Route | Capability demonstrated |
|---|---|
| `/test-echo` | baseline echo (control + benchmark + readiness probe) |
| `/t-req-header` | request header replace (`request-transformer`) |
| `/t-req-json` | request JSON body replace (`request-transformer`) |
| `/t-resp-header` | response header add (`response-transformer`) |
| `/fixed-ok` | response JSON key rename (`oss-post`) |
| `/empty`, `/not-json`, `/echo-error` | edge responses (empty / non-JSON / 500) with `oss-post` active |
| `/t-pre` | `oss-pre`: auth + correlation id + request rename |
| `/t-post` | `oss-pre` + `oss-post`: correlation echo + response rename |
| `/secure-echo` | `oss-pre` auth only (X-Api-Key presence) |
| `/combined-echo` | full chain: pre + post on one route |

Enabling a plugin on your own route is one `POST /services/{id}/plugins`
call — exact config fields in
[docs/CONFIGURATION.md](docs/CONFIGURATION.md#routes-and-plugins-created-by-scriptsconfiguresh).

## 9. Custom plugins (oss-pre / oss-post)

| Plugin | Phases | What it does |
|---|---|---|
| [`oss-pre`](plugins/oss-pre/) | access + header_filter | required-header validation (controlled 400 JSON), correlation-id generation/preservation (`oss-…`, echoed in response header), top-level JSON request-body key renames — bounded `max_body_bytes` budget; over-budget bodies pass through intact |
| [`oss-post`](plugins/oss-post/) | access + header_filter + body_filter | adds a response header (default `X-Oss-Post: processed`), echoes a request header back (e.g. the correlation id), top-level JSON response-body key renames — incremental budget, over-budget responses pass through complete; transform routes framed chunked (documented) |

Both plugins are memory-bounded, `pcall`-wrapped (malformed JSON never
causes a 500), log no secrets, and are mounted **read-only**.

Known Kong-side pitfalls they work around (see §21): nested relation
objects, no top-level `/targets`, async route-cache invalidation.

## 10. Management UI

`panel/manage.py` — single-file, stdlib-only web UI for the Admin API:

- Login (file-backed users, `MANAGE_USERS`), roles **admin** / **viewer**
- Browsable CRUD for services / routes / plugins / consumers / key-auth
- **Audit log** of every admin action (user, IP, method, path, code, ms)
- **Per-entity JSON backup** before every destructive change
- Session cookies, constant-time password compare, CSP with nonce

Deployed (labeled, live): `53:18091` and behind `52:443 /admin/`.
Tests: `tests/test_manage.py` (live) + `tests/test_manage_base.py`
(throwaway instance). Deploy/verify scripts for both hosts were executed
in Phase 3 (recorded in PROJECT_AUDIT.md §5).

## 11. AI gateway (LiteLLM-like)

`scripts/ai-gateway.sh` (idempotent, executed on the AI host) creates:

- consumer `ai-consumer` + **real `key-auth` credential** (stored in a
  mode-600 CREDS file; never printed)
- service `ai-gw` → `AI_HOST:8000` (vLLM, OpenAI-compatible)
- route `/ai` (strip_path) → upstream `/v1/*`
- route-scoped plugins: `key-auth`, `rate-limiting` (local, 30/min + 5/s),
  `oss-pre` (correlation id), `post-function` (**metadata-only** log:
  ts, method, path, status, duration_ms, correlation_id, consumer —
  **prompt bodies are never logged**)

Verified live (9/9): 401 no-key / 401 bad-key, 200 real completion with
`chat.completion` + `X-Correlation-Id`, rate limiting (11×429 in a 16
burst), upstream 404 passthrough, `/ai/v1/models` 200, metadata log
present with no prompt content, idempotent re-run.

**Responsibility boundary:** Kong enforces auth, routing, rate limit,
metadata. Model routing / key pooling / fallbacks belong to the LiteLLM
tier when present. **Provider keys never enter Kong** — only the one
gateway API key for clients lives in Kong.

## 12. Static API docs page

`scripts/gen-api-docs.py <admin-url> <out.html>` renders a self-contained
static API docs page from the live Admin API (services, routes, methods,
upstream resolution). No Swagger/OpenAPI dependency.

Deployed (labeled, live): `52:443 /apidocs/` — 401 without admin
credentials, 200 with, 301 on the bare path (verified).

## 13. GitOps: export / import / backup / restore / rollback

Full guide + runbooks: [docs/GITOPS.md](docs/GITOPS.md).

| Script | What it does |
|---|---|
| `scripts/export.sh` | live Admin API → `_export/kong-gateway.json` (+ `.yml` twin). **Contains key-auth keys — directory is git-ignored.** |
| `scripts/import.sh` | declarative file → live, additive + idempotent (nested endpoints, never deletes) |
| `scripts/backup.sh` | snapshot to `_backup/<utc-ts>/`: export + `pg_dump` + `manifest.json` (sha256 of every file + kong version); dir mode 700; prunes to 10 (`BACKUP_KEEP`) |
| `scripts/restore.sh` | `restore.sh <snap> --config` (additive import) or `--database` (full rewind: DROP/CREATE + psql import). **Takes an automatic safety snapshot first** and hash-verifies the snapshot against its manifest before touching anything |
| `scripts/rollback.sh` | `--list` (snapshots + age) or `<snap>` → declarative rollback + `smoke-test.sh` |

Clean-clone acceptance (Phase 6) exercised the full loop on a disposable
stack (`kong-gw-cleantest`, 19080/19001) while production ran untouched:
setup → 14/14 smoke → 18/18 + 9/9 tests → first backup snapshot.

## 14. Testing

```bash
bash scripts/smoke-test.sh     # 14 fast e2e checks (fastest regression gate)
bash scripts/run-tests.sh      # 18 mandatory (T01–T18) + 9 boundary (B1–B9)
bash scripts/security-test.sh  # 11 security posture checks
```

Mandatory suite covers: stack health, Admin API config integrity,
direct + proxied echo, both custom plugins, header/body transforms with
controls, auth positive/negative, invalid payload handling, 100-request
runs (plain + plugin-loaded), latency percentiles (p95 < 1000 ms gate),
0-error mixed load, restart stability (12-route fingerprint), loopback
exposure check. Boundary suite covers the 1 MiB transform budget in
both directions, empty/non-JSON/500 responses, chunked framing, and
correlation-id consistency under concurrency.

Management-UI suites: `tests/test_manage.py` (live),
`tests/test_manage_base.py` (throwaway instance). `tests/test_yaml2json.py`:
26 fixture conformance.

Reports: `tests/results/*.txt`, `benchmark/results/*` (git-ignored).
Methodology: [docs/TESTING.md](docs/TESTING.md).

## 15. Security posture

- **Loopback-only** host ports (proxy + admin); Postgres and echo have
  **no** host ports. Verified by T18 + `security-test.sh`.
- Pinned image tags; read-only plugin bind mounts; `.env` git-ignored
  (mode 600); no secrets in the repository (sanitization scan clean;
  the only exceptions are two documented ephemeral test-fixture
  credentials that are environment-injected into a throwaway instance).
- Memory-bounded transforms with deterministic pass-through for
  over-budget bodies (nothing dropped, nothing unbounded); malformed
  JSON never 500s (pcall-wrapped).
- Controlled 400 JSON error bodies (no stack traces, no upstream leaks).
- **OSS auth note:** the *demo* routes use `oss-pre` header-**presence**
  gating (documented, not key validation); the *AI route* uses real
  `key-auth`. There is no consumer-level RBAC in OSS (no ACL plugin).
- **Not included (OSS gaps):** TLS termination, WAF, JWT/OAuth2,
  consumer ACLs, mTLS. Hardening checklist for production:
  [docs/SECURITY.md](docs/SECURITY.md#recommended-hardening-checklist-for-production).

## 16. Performance (benchmark)

```bash
bash scripts/benchmark.sh      # 3 rounds × 100 measured reqs, direct vs Kong
```

One fresh connection per request, 20 warmups excluded per block,
alternating order, nearest-rank percentiles, every request validated.
Client runs on the internal network (no host ports; modest non-destructive
load). Outputs: `benchmark/results/{results.json,results.csv,meta.json,env.txt}`.

Fresh numbers from the clean-clone acceptance run (2026-10-20):
p50 ≈ 1.2 ms, p95 ≈ 2.0 ms, p99 ≈ 2.3 ms through Kong (T15). Full
methodology + how to re-run: [docs/TESTING.md](docs/TESTING.md#benchmark-methodology).

## 17. Logs & observability

```bash
docker compose logs -f --tail 100          # all services
docker compose logs --tail 50 kong         # proxy + admin side
docker compose logs --tail 50 db           # postgres
```

Kong writes structured access/error logs to stdout/stderr; json-file
rotation (10 MB × 3) per container. The AI route emits one WARN-level
metadata JSON line per request (`ai-gw-meta: {...}`) — grep for
`ai-gw-meta` in `docker logs <project>-kong`.

**Pitfalls (why it's WARN-level and why no cjson):** `log_by_lua*`
sandbox forbids `require 'cjson'`, and `KONG_LOG_LEVEL=notice` (default)
suppresses `ngx.INFO`; also `kong.service.request` accessors are nil in
the LOG phase — use `ngx.var.request_method` / `ngx.var.uri` (see §21).

## 18. Operations: restarts, upgrades, multi-env

```bash
bash scripts/restart-test.sh     # kong restart + 12-route fingerprint check
```

Version update: bump `KONG_VERSION` in `.env`, `docker compose pull`,
`docker compose up -d`, wait healthy, re-run `configure.sh` + smoke
(one-shot `migrate` service runs `kong migrations up` on every start).
Rollback = restore previous `KONG_VERSION` + `docker compose up -d`, or
use `scripts/rollback.sh` for config-level rollback. Details:
[docs/CONFIGURATION.md](docs/CONFIGURATION.md#version-update-kong-or-postgresql).

Multi-env (namespaced, proven side-by-side on one host):

| Env | Project name | Ports |
|---|---|---|
| dev | `kong-gw-dev` | 18080 / 18001 |
| staging | `kong-gw-staging` | 19080 / 19001 |
| prod | `kong-gw-prod` | loopback behind TLS (e.g. 52's nginx vhost) |

Admin API stays loopback-only in every env. Runbook + the compose
working-directory pitfall: [docs/GITOPS.md](docs/GITOPS.md).

## 19. Troubleshooting

[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) covers port conflicts,
DB password/volume issues, plugin load errors, route wiring, auth 400s,
chunked responses, admin API access, benchmark oddities, safe reset
(`docker compose down -v` + `setup.sh`), and the "routes exist in Admin
but proxy 404s" symptom (data-plane lag — `setup.sh` now waits for it;
on manual installs, poll the baseline route for up to ~30 s).

## 20. OSS limitations & honest gaps

Explicitly **not** available in Kong OSS (this is the OSS edition; we do
not paper over it):

- No consumer ACLs, JWT, OAuth2, HMAC, mTLS, SNI termination
- No declarative DB mode — GitOps tooling is Admin-API based
  (additive import; deletions are manual or via DB restore)
- No built-in TLS termination — put nginx/ALB in front (52 reference)
- No WAF, no bot detection
- `rate-limiting` is per-DB (local policy) — cluster policy needs a
  datastore Kong already has, but enterprise features (Policies UI,
  control plane) are not in OSS
- No key rotation UI — rotate by regenerating the key-auth credential
  (Admin API) and updating clients

Everything in §2's matrix is tagged so the receiving team sees exactly
what is OSS-native, what is custom-built here, and what is out of scope.

## 21. Kong 3.9.4 Admin API findings (pitfall list)

All nine were hit live and are documented in
[PROJECT_AUDIT.md §6.3 + §7.4](docs/PROJECT_AUDIT.md); the scripts
already work around them:

1. Nested relation objects — `route.service` is `{id}` not a string.
2. No top-level `/targets` list endpoint — use `/upstreams/{id}/targets`.
3. Route-cache invalidation is **async** — proxy can 404 up to ~30 s after
   route creation (setup.sh now waits; poll in manual installs).
4. DELETE cascade + **top-level PUT nulls relations** — always link/update
   via nested endpoints (`/services/{id}/routes`, `/services/{id}/plugins`).
5. Key-auth credentials live under the **singular** `/consumers/{u}/key-auth`.
6. `?name=` list filters are unreliable — filter client-side on full lists.
7. Name-based nested route refs 404 — use route **IDs**.
8. PUT on a route without `name` clears the name.
9. `log_by_lua*` sandbox: no `require 'cjson'`; `ngx.INFO` suppressed at
   `notice` (use WARN); `kong.service.request` accessors nil in LOG phase
   (use `ngx.var.*`).

## 22. Documentation & training map

| Doc | Content |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | step-by-step install, every command verified |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | `.env`, routes/plugins reference, version updates |
| [docs/SECURITY.md](docs/SECURITY.md) | posture, auth model, production hardening checklist |
| [docs/TESTING.md](docs/TESTING.md) | suite descriptions, methodology, benchmark |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | symptoms → fixes |
| [docs/GITOPS.md](docs/GITOPS.md) | GitOps loop, backup/restore/rollback runbooks, multi-env |
| [docs/CAPABILITY_MATRIX.md](docs/CAPABILITY_MATRIX.md) | tagged capability matrix |
| [docs/PROJECT_AUDIT.md](docs/PROJECT_AUDIT.md) | full execution record: every phase, real command output, damage/repair disclosures |
| [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) | the 12-phase plan with ✅ results |
| [AGENT_HANDOFF.md](AGENT_HANDOFF.md) | operator/agent handover snapshot |

An 8-session operator training course is in `docs/training/` (Phase 9
deliverable; labs use throwaway `train-` prefixed routes and
`/test-echo`, never live production paths).

## 23. AI-agent workflow

When an AI coding/ops agent works on this project, it should:

1. **Read the docs first**: `docs/INSTALL.md` → `CONFIGURATION.md` →
   `TESTING.md`. All commands are self-verifying (scripts print
   PASS/FAIL and exit non-zero on failure).
2. **Verify with the scripts, not guesswork**: `bash scripts/smoke-test.sh`
   after any change; `bash scripts/run-tests.sh` before declaring a change
   complete.
3. **Never touch `.env` values in commits**; the file is git-ignored.
   Password rotation: change `.env`, then `docker compose up -d db`
   (or `down -v` + `setup.sh` if the volume predates the change).
4. **Config changes go through `scripts/configure.sh`** (idempotent Admin
   API upserts) — no hand-crafted one-off Admin API calls.
5. **Plugin changes**: edit `plugins/<name>/handler.lua` + `schema.lua`,
   `docker compose up -d kong` (reload), run smoke + tests. Keep the
   contracts: bounded bodies, pcall-wrapped JSON, no secrets in logs,
   controlled error JSON.
6. **Isolation rules**: never stop/restart/delete containers, volumes or
   networks that don't carry the `${COMPOSE_PROJECT_NAME}` prefix. Always
   `cd` into the stack's own checkout before compose commands (§6 gotcha).
7. **Benchmarking**: use `scripts/benchmark.sh` (sized to stay
   non-destructive).

## 24. Verification status & how to re-verify

**Recorded runs (all executed, not cited):**

| Run | Evidence |
|---|---|
| Clean-clone install from GitHub `main` (commit `6585786`), host 53, project `kong-gw-cleantest` on 19080/19001 | setup PASS (incl. data-plane convergence), smoke **14/14**, tests **18/18** (T15 p95=2.049 ms; T16 0 errors/200), boundary **9/9**, first backup snapshot OK — `CLEAN-CLONE-RESULT: FAILS=0` |
| AI gateway live suite (`ai-test53.sh`) | **9/9 PASS** (auth ×2, real LLM 200, 11×429 rate limit, 404 passthrough, models 200, metadata log w/o prompt, idempotency) |
| Management UI (53:18091, 52:443/admin/) | all deploy + API checks green (PROJECT_AUDIT.md §5) |
| Production inventory (53) | 11 services / 13 routes / 15 plugins, `/test-echo` 200, `/status` 200 |
| GitOps export/import | 12/12 entity round-trip (Phase 4) |

**How to re-verify from scratch (the acceptance sequence):**

```bash
git clone <repo-url> kong-gw-test && cd kong-gw-test
# .env.example: COMPOSE_PROJECT_NAME=kong-gw-cleantest
#               KONG_PROXY_PORT=19080  KONG_ADMIN_PORT=19001
bash scripts/setup.sh && bash scripts/smoke-test.sh \
  && bash scripts/run-tests.sh && bash scripts/backup.sh
```

Any command in this README that has *not* been executed in the final
acceptance pass is explicitly labeled "(not re-run in final pass)" —
the Phase 10 acceptance record (PROJECT_AUDIT.md §10) closes that list.

---

**Sanitization note:** this repo contains no internal IPs or personal
paths; where host-52/53 addresses are referenced in docs, they use the
TEST-NET-2 placeholder `198.51.100.x` (mapping documented in
[PROJECT_AUDIT.md](docs/PROJECT_AUDIT.md) header).
