# Troubleshooting

Quick diagnosis guide. For every symptom: check the command first,
then the fix.

## Nothing starts / `docker compose up` fails

| Symptom | Check | Fix |
|---|---|---|
| `port is already allocated` | `ss -ltn \| grep -E '18080\|18001'` | pick free ports in `.env` (`KONG_PROXY_PORT`, `KONG_ADMIN_PORT`) and re-run `docker compose up -d` |
| `denied: requested access to the resource is denied` (pull) | registry reachability / credentials | check network or configure `docker login` |
| `KONG_PG_PASSWORD is not set` | `grep KONG_PG_PASSWORD .env` | create `.env` from `.env.example` with a strong random password (see INSTALL.md step 3) |
| migrate container restarts / exits 1 | `docker compose logs migrate` | usually DB not reachable: check `db` health (`docker compose ps`), then `docker compose up -d` again |

## Kong container is `restarting` or unhealthy

```bash
docker compose logs --tail 50 kong
```

| Symptom | Cause | Fix |
|---|---|---|
| `FATAL ... database: connection refused` | DB not ready / wrong host | `KONG_PG_HOST` must be `${COMPOSE_PROJECT_NAME}-db` (compose default) — don't override unless you know why |
| `FATAL ... bad password` | `KONG_PG_PASSWORD` changed but DB volume predates it | either restore the old password, or (destructive) `docker compose down -v` and start fresh |
| plugin load errors mentioning `oss-pre`/`oss-post` | plugin dir not mounted / lua syntax error | verify `docker compose config` shows both bind mounts; `docker compose logs kong \| grep -i 'oss-'` |
| `address already in use` on 8000/8001 **inside** the network | another stack on the same network (wrong project name) | use a unique `COMPOSE_PROJECT_NAME` |

## DB (PostgreSQL) problems

```bash
docker compose ps db
docker compose logs --tail 50 db
docker exec ${COMPOSE_PROJECT_NAME:-kong-gw-oss}-db psql -U kong -d kong -c 'select 1'
```

- `pg_isready` failing → volume on a full disk (`df -h .`), or an
  incompatible data dir. The volume is named
  `${COMPOSE_PROJECT_NAME}-pgdata`; **deleting it destroys the DB** —
  back up first (`docker compose exec db pg_dumpall -U kong > backup.sql`).
- Slow admin API / queries: check `KONG_LOG_LEVEL` (use `notice`, not
  `debug`, in production).

## Requests fail through Kong but work direct

| Symptom | Check | Fix |
|---|---|---|
| `503 Service Unavailable` / `502` on a route | route→service wiring | `curl -s http://127.0.0.1:18001/routes?size=100` ; re-run `bash scripts/configure.sh` |
| `404` on a path | route missing | same: re-run configure |
| upstream `echo` errors in kong logs | service host wrong | services point at host `echo:9000` (compose service DNS). If you renamed the service, set `ECHO_HOST` for configure.sh |
| `504` gateway timeout | upstream slow/hung | `docker compose ps echo`, try direct `docker exec ${COMPOSE_PROJECT_NAME}-echo wget -qO- http://127.0.0.1:9000/health` |

## Auth / plugin behavior surprises

| Symptom | Explanation |
|---|---|
| `400 {"error":"missing_required_header",...}` on `/secure-echo`, `/t-pre`, `/combined-echo` | **expected** — those routes require `X-Api-Key` (any non-empty value). Send the header to proceed. |
| response is `Transfer-Encoding: chunked` and has no `Content-Length` | **expected** on transform routes (`/fixed-ok`, `/t-post`, `/combined-echo`, edge routes): `oss-post` clears Content-Length when a body transform is configured so the client framing stays valid. |
| large body (>1 MiB) is not transformed | **by design** (`max_body_bytes` budget). It passes through **intact**; raise the budget in the plugin config if you really need to transform it (cap 10 MiB). |
| correlation id not echoed | the route's `oss-post` must have `echo_request_header` set; generated ids use the `oss-` prefix. |

## Admin API

- `curl http://127.0.0.1:18001/` should return `{"version":"3.9.4",...}`.
- If the Admin API is unreachable but the proxy works: the kong
  container is fine; check the published port mapping
  (`docker port ${COMPOSE_PROJECT_NAME}-kong`) and that
  `KONG_ADMIN_PORT` in `.env` matches what the script uses.
- **Never** bind the Admin API to a non-loopback interface.

## Performance / benchmark oddities

- High p95 with a healthy stack: check host load
  (`uptime`, `docker stats`), the benchmark uses a fresh connection per
  request (conservative by design).
- Overhead (Kong − direct) is large only if you attach many plugins to
  the benchmarked route; the baseline `/test-echo` route has none.
- To re-baseline after changes: `bash scripts/benchmark.sh` again and
  compare `benchmark/results/results.json` against the previous run
  (results are overwritten each run — copy them aside first if you
  need history).

## Logs

```bash
docker compose logs -f --tail 100            # all services
docker compose logs --tail 100 kong          # proxy side
docker compose logs --tail 100 db            # postgres side
```

Kong emits structured access/error logs to stdout/stderr (json-file
driver, 10 MB × 3 rotations per container — see `docker-compose.yml`).

## Resetting to a known-good state

```bash
# stop, keeping the database:
docker compose down

# FULL reset (destructive — deletes the database volume):
docker compose down -v
bash scripts/setup.sh        # rebuilds .env, images, config from scratch
```
