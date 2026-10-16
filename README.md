# Kong OSS API Gateway — Standalone Release

A complete, self-contained [Kong OSS](https://kong.org/kong-gateway/) API
gateway deployment with Docker Compose, two hardened custom Lua plugins
(`oss-pre`, `oss-post`), a deterministic test backend, an automated
test suite (18 mandatory tests + 9 security boundary cases), a
latency/throughput benchmark, and full documentation.

> **📖 Start here → [docs/INSTALL.md](docs/INSTALL.md)** — every command
> below is verified and documented there, step by step.

## Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Repository layout](#repository-layout)
- [Routes & demo capabilities](#routes--demo-capabilities)
- [Testing](#testing)
- [Benchmark](#benchmark)
- [Logs](#logs)
- [Troubleshooting](#troubleshooting)
- [Version update](#version-update)
- [Security notes](#security-notes)
- [Deploying to another server](#deploying-to-another-server)
- [AI-agent workflow](#ai-agent-workflow)

## Architecture

```
                     internal network: <project>-net  (no internet exposure)
+----------------------------------------------------------------------------+
|  client                                                                     |
|    │  http://127.0.0.1:18080  (Proxy — loopback only)                       |
|    ▼                                                                        |
|  kong (kong:3.9.4, OSS)                                                     |
|    ├─ Admin API  http://127.0.0.1:18001  (loopback only)                    |
|    ├─ plugins: bundled + oss-pre + oss-post  (read-only bind mounts)        |
|    ├─ PostgreSQL:  <project>-db (postgres:16.6-alpine, NO host ports)       |
|    │              volume: <project>-pgdata                                  |
|    └─► echo:9000   deterministic test backend (no host ports)               |
|                                                                             |
|  migrate: one-shot `kong migrations up` (bootstrap on first run),           |
|           kong waits for it (service_completed_successfully)                |
+----------------------------------------------------------------------------+
```

- **Fully isolated**: every container, volume and network is prefixed with
  `COMPOSE_PROJECT_NAME` (default `kong-gw-oss`), so multiple stacks can
  coexist on one host.
- **Only loopback host ports** are published (18080 proxy, 18001 admin).
  PostgreSQL and the echo backend have no host ports at all.
- **Env-driven configuration**: everything tunable lives in `.env`
  (see [docs/CONFIGURATION.md](docs/CONFIGURATION.md)). No internal
  IPs, no organizational context required to run.

## Custom plugins

| Plugin | Phases | What it does |
|---|---|---|
| [`oss-pre`](plugins/oss-pre/) | access + header_filter | required-header validation (controlled 400 JSON error), correlation-id generation/preservation (`oss-…`, echoed back in the response header), top-level JSON request-body key renames — all with a bounded `max_body_bytes` budget (over-budget bodies pass through intact) |
| [`oss-post`](plugins/oss-post/) | access + header_filter + body_filter | adds a response header (default `X-Oss-Post: processed`), echoes a request header back (e.g. the correlation id), top-level JSON response-body key renames — incremental budget, over-budget responses pass through complete; transform routes are framed chunked (documented) |

Both plugins are memory-bounded, `pcall`-wrapped (malformed JSON never
causes a 500), log no secrets, and are mounted **read-only**.

## Prerequisites

- Linux (or Docker Desktop) with **Docker Engine ≥ 24** and
  **Docker Compose v2** (`docker compose version`)
- `curl` and `python3` (standard library only — no pip installs)
- ~1 GB free disk, and free loopback ports 18080 + 18001
  (both changeable in `.env`)

```bash
docker version && docker compose version
```

## Quick start

All commands are run from the repository root.

```bash
# 0) get the code
git clone <repo-url> kong-api-gateway-oss
cd kong-api-gateway-oss

# 1) configure the environment
cp .env.example .env
sed -i 's/^KONG_PG_PASSWORD=.*/KONG_PG_PASSWORD='$(openssl rand -hex 24)'/' .env
chmod 600 .env

# 2) validate + start (first run builds the echo backend image)
docker compose config -q
docker compose up -d --build
docker compose ps                    # wait until db + kong are "healthy"

# 3) initial Kong setup (idempotent: 10 services, 12 routes, plugins)
bash scripts/configure.sh

# 4) smoke test (14 checks)
bash scripts/smoke-test.sh

# 5) full test suite (18 mandatory + 9 boundary)
bash scripts/run-tests.sh

# 6) security posture checks
bash scripts/security-test.sh

# 7) benchmark
bash scripts/benchmark.sh
```

> **One-shot alternative:** `bash scripts/setup.sh` performs steps
> 1–3 (including password generation) automatically.

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

## Repository layout

```
├── docker-compose.yml       # the whole stack (env-driven)
├── .env.example             # template — copy to .env
├── .gitignore
├── plugins/
│   ├── oss-pre/             # custom request pre-processing plugin
│   └── oss-post/            # custom response post-processing plugin
├── echo/                    # deterministic test backend (stdlib Python)
├── bench/                   # benchmark client (stdlib Python)
├── scripts/
│   ├── setup.sh             # one-shot install (env + start + configure)
│   ├── configure.sh         # idempotent Admin API configuration
│   ├── smoke-test.sh        # 14 fast e2e checks
│   ├── run-tests.sh         # 18 mandatory + 9 boundary tests
│   ├── security-test.sh     # 11 security posture checks
│   ├── restart-test.sh      # kong restart + stability fingerprint
│   ├── benchmark.sh         # direct-vs-Kong latency benchmark
│   └── _common.sh           # shared helpers (env, compose, waits)
├── tests/
│   ├── test_suite.py        # T01–T18 (mandatory)
│   ├── boundary.py          # B1–B9 (security boundary)
│   └── results/             # reports (git-ignored)
├── benchmark/results/       # benchmark outputs (git-ignored)
└── docs/
    ├── INSTALL.md           # ← start here
    ├── CONFIGURATION.md
    ├── SECURITY.md
    ├── TESTING.md
    └── TROUBLESHOOTING.md
```

## Routes & demo capabilities

Created by `scripts/configure.sh` (idempotent):

| Route | Capability demonstrated |
|---|---|
| `/test-echo` | baseline echo (control + benchmark) |
| `/t-req-header` | request header replace (`request-transformer`) |
| `/t-req-json` | request JSON body replace (`request-transformer`) |
| `/t-resp-header` | response header add (`response-transformer`) |
| `/fixed-ok` | response JSON key rename (`oss-post`) |
| `/empty`, `/not-json`, `/echo-error` | edge responses (empty / non-JSON / 500) with `oss-post` active |
| `/t-pre` | `oss-pre`: auth + correlation id + request rename |
| `/t-post` | `oss-pre` + `oss-post`: correlation echo + response rename |
| `/secure-echo` | `oss-pre` auth only (X-Api-Key presence) |
| `/combined-echo` | full chain: pre + post on one route |

Enabling a plugin on your own route is one `POST /plugins` call — see
[docs/CONFIGURATION.md](docs/CONFIGURATION.md#routes-and-plugins-created-by-scriptsconfiguresh)
for the exact configuration fields of both custom plugins.

## Testing

```bash
bash scripts/run-tests.sh        # 18 mandatory (T01–T18) + 9 boundary (B1–B9)
```

The 18 mandatory tests cover: stack health, Admin API configuration
integrity, direct + proxied echo, both custom plugins, header/body
transforms (with controls), authentication positive/negative, invalid
payload handling, 100-request runs (plain and plugin-loaded), latency
percentiles, error rate, restart stability, and Admin-API
non-exposure. Full descriptions in [docs/TESTING.md](docs/TESTING.md).

Reports: `tests/results/test-suite-report.txt`, `tests/results/boundary-report.txt`.

## Benchmark

```bash
bash scripts/benchmark.sh        # 3 rounds × 100 measured reqs, direct vs Kong
```

One fresh connection per request, 20 warmups excluded per block,
alternating order, nearest-rank percentiles, every request validated.
The client runs on the internal network (no host ports, modest default
load — non-destructive). Outputs: `benchmark/results/results.json`,
`results.csv`, `meta.json`, `env.txt`. Methodology:
[docs/TESTING.md](docs/TESTING.md#benchmark-methodology).

## Logs

```bash
docker compose logs -f --tail 100          # all services
docker compose logs --tail 50 kong         # proxy + admin side
docker compose logs --tail 50 db           # postgres
```

Kong writes structured access/error logs to stdout/stderr; json-file
rotation (10 MB × 3) is configured per container.

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — covers
port conflicts, DB password/volume issues, plugin load errors, route
wiring, auth 400s, chunked responses, admin API access, benchmark
oddities, and safe reset procedures.

## Version update

Bump the pinned tag and re-apply — the one-shot `migrate` service runs
`kong migrations up` on every start:

```bash
# .env
#   KONG_VERSION=3.9.5
docker compose pull
docker compose up -d
docker compose ps                     # wait for healthy
bash scripts/configure.sh             # idempotent re-assert
bash scripts/smoke-test.sh
```

Rollback = restore the previous `KONG_VERSION` and `docker compose up -d`.
Details in [docs/CONFIGURATION.md](docs/CONFIGURATION.md#version-update-kong-or-postgresql).

## Security notes

- Loopback-only exposure; Admin API never bound to a non-loopback
  interface; PostgreSQL on an internal-only network; read-only plugin
  mounts; pinned images; git-ignored `.env`; no secrets in the repo.
- Memory-bounded transforms with deterministic pass-through for
  over-budget bodies (nothing dropped, nothing unbounded).
- Auth on OSS: `X-Api-Key` **presence** check via `oss-pre` — Kong OSS
  has no key-auth plugin, so this is a controlled gate, not key
  validation. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md#authentication-kong-oss).
- **Not** TLS termination, not a WAF, not rate limiting — those are
  listed as recommended production additions in
  [docs/SECURITY.md](docs/SECURITY.md#recommended-hardening-checklist-for-production).

## Deploying to another server

The stack is fully portable:

```bash
# on the target server (needs Docker + compose v2 + curl + python3):
git clone <repo-url> kong-api-gateway-oss && cd kong-api-gateway-oss
bash scripts/setup.sh                # creates .env (strong random pw), builds,
                                     # starts, configures
bash scripts/smoke-test.sh           # verify
bash scripts/run-tests.sh            # full verification
```

If you need different ports (host already busy):

```bash
# in .env:  KONG_PROXY_PORT=19080   KONG_ADMIN_PORT=19001
docker compose up -d
```

To run two isolated stacks side by side, change
`COMPOSE_PROJECT_NAME` (and the two ports) in a second `.env` copy —
all resources are namespaced.

## AI-agent workflow

When an AI coding/ops agent works on this project, it should:

1. **Read the docs first**: `docs/INSTALL.md` → `CONFIGURATION.md` →
   `TESTING.md`. All commands are self-verifying (scripts print
   PASS/FAIL and exit non-zero on failure).
2. **Verify with the scripts, not guesswork**:
   `bash scripts/smoke-test.sh` after any change;
   `bash scripts/run-tests.sh` before declaring a change complete.
3. **Never touch `.env` values in commits**; the file is git-ignored.
   If a password must be rotated: change `.env`, then
   `docker compose up -d db` (or a full `down -v` + `setup.sh` if the
   DB volume predates the change).
4. **Config changes go through `scripts/configure.sh`** (idempotent
   Admin API upserts) — do not hand-craft one-off Admin API calls that
   the script doesn't know about, or re-add them to the script.
5. **Plugin changes**: edit `plugins/<name>/handler.lua` + `schema.lua`,
   then `docker compose up -d kong` (reload), run
   `bash scripts/smoke-test.sh` and `bash scripts/run-tests.sh`.
   Keep the documented contracts: bounded bodies, pcall-wrapped JSON,
   no secrets in logs, controlled error JSON.
6. **Isolation rules**: never stop/restart/delete containers, volumes
   or networks that don't carry the `${COMPOSE_PROJECT_NAME}` prefix.
7. **Benchmarking**: use `scripts/benchmark.sh` (sized to stay
   non-destructive). Don't add load that other host services must
   absorb.

---

**Status:** final release candidate — see `AGENT_HANDOFF.md` / the
release report for the verified test run (18/18 + 9/9) and benchmark
numbers from the isolated validation host.
