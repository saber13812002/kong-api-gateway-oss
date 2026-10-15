# Kong Gateway — Isolated Trial (s52)

STEP 1.2 of the Kong OSS project. A **throwaway, fully isolated** Kong + PostgreSQL
stack on server **s52 (172.20.1.52)** for pre-evaluation only. It is *not* the
production gateway (planned target: dedicated VM).

## Design decisions

| Item | Value | Why |
|---|---|---|
| Kong | `kong:3.9.4` (pinned) | Latest stable OSS per official Docker Hub tags (checked 2026-10-15) |
| PostgreSQL | `postgres:16.6-alpine` | Compatible with Kong 3.9 (supports PG 9.6–16) |
| Proxy | `127.0.0.1:18080` | Loopback only — not reachable from the network |
| Admin API | `127.0.0.1:18001` | Loopback only — never internet-exposed |
| PostgreSQL ports | none on host | Internal Docker network only |
| DB storage | named volume `kong-gw-trial_kong-gw-trial-pgdata` | Persistent across container recreation |
| Project name | `kong-gw-trial` | Namespaced containers/networks/volumes — no collision with existing services |

Everything uses the prefix `kong-gw-trial-` (containers, network, volume) so this
stack can never touch the 36+ containers already running on s52.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | DB + one-shot migration + Kong + echo backend |
| `.env` | `KONG_PG_PASSWORD` (random 32-char, **git-ignored**) |
| `.env.example` | Template for `.env` |
| `.gitignore` | Keeps secrets out of version control |
| `echo/Dockerfile` + `echo/app.py` | Deterministic echo backend (pinned `python:3.12.11-alpine3.21`, stdlib only) |
| `tmp/step2-configure.sh` | Idempotent Kong Service/Route creation (re-runnable) |
| `tmp/step2-tests.sh` | STEP 2 functional test suite (5 tests) |

## How it works

1. `kong-gw-trial-db` — PostgreSQL 16, healthchecked via `pg_isready`, data in
   the named volume. `POSTGRES_HOST_AUTH_METHOD=trust` on the internal-only
   network lets the migration service bootstrap without the password; the
   `kong-gw-trial-kong` container still authenticates with `KONG_PG_PASSWORD`.
2. `kong-gw-trial-migrate` — one-shot `kong migrations up || kong
   migrations bootstrap`; exits 0 on success. Never restarts (`restart: "no"`).
3. `kong-gw-trial-kong` — starts only after the migration service completes
   successfully (`depends_on: service_completed_successfully`); runs the
   default `kong start`. Healthcheck: `kong health`.
4. `kong-gw-trial-echo` — STEP 2 deterministic echo backend; listens on port
   9000 **inside** `kong-gw-trial-net` only (no host port).

## STEP 2 — test topology

```
client (s52 host)
  -> Kong Proxy  127.0.0.1:18080
     route  /test-echo  (strip_path=true, methods GET+POST)
       service test-echo-service -> http://kong-gw-trial-echo:9000
         echo backend (Docker-internal, /health endpoint)
```

`strip_path=true` is explicit: the `/test-echo` prefix is removed before the
request hits the backend, so the backend sees `/` (plus query string). Kong
adds `X-Forwarded-Path`/`X-Forwarded-Prefix` so the original prefix is still
visible to the upstream.

Configuration is **idempotent** (`tmp/step2-configure.sh`): the service is
upserted with `PUT /services/{name}` and the route is found by
`(service_id, paths)` then updated or created. Rerunning never creates
duplicates (verified: still 1 service / 1 route after rerun).

Quick re-test:

```bash
bash tmp/step2-configure.sh   # safe to rerun
bash tmp/step2-tests.sh       # 5 functional tests, prints raw curl output
```

## Operations (run on s52, inside this directory)

```bash
# validate (no side effects)
docker compose -p kong-gw-trial config --quiet

# start everything (DB -> migrate -> Kong)
docker compose -p kong-gw-trial up -d

# status / logs
docker compose -p kong-gw-trial ps
docker compose -p kong-gw-trial logs --tail=50 kong-gw-migrate

# smoke tests
curl -s http://127.0.0.1:18001/          # Admin API: version JSON
curl -s http://127.0.0.1:18080/          # Proxy: 404 {"message":"no route matched"}

# tear down (keeps the database volume)
docker compose -p kong-gw-trial down
```

### Safety rules

- **Never** run `docker compose down -v` (would delete the DB volume) or
  `docker system prune` on this host.
- Never add `0.0.0.0` port bindings or extra networks to this compose file.
- Do not restart or remove any pre-existing container on s52.
- If the volume must be destroyed, do it explicitly:
  `docker volume rm kong-gw-trial_kong-gw-trial-pgdata` — only after full
  teardown.

## Upcoming steps (not yet implemented)

- STEP 2: test API + real request/response through the proxy
- STEP 3: 100-request latency benchmark
- STEP 4: pre/post transformation + 100-request test
- Later: HTTPS (TLS termination), dedicated-VM production deployment
