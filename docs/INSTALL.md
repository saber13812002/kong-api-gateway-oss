# Installation Guide

Standalone installation of the Kong OSS API Gateway release with Docker
Compose. Every step below is a verified command — run them in order from
the release root directory.

## 1. Prerequisites

| Requirement | Checked by | Notes |
|---|---|---|
| Linux host (or Docker Desktop) with **Docker Engine ≥ 24** | `docker version` | |
| **Docker Compose v2** | `docker compose version` | the `docker compose` plugin, not the legacy `docker-compose` |
| `curl`, `python3` (stdlib only) | `command -v curl python3` | used by scripts/tests |
| ~1 GB free disk for images | `df -h .` | kong + postgres + echo images |
| Free loopback ports **18080** and **18001** | `ss -ltn` | changeable via `.env` (see CONFIGURATION.md) |

```bash
docker version
docker compose version
```

## 2. Get the code

```bash
# clone the release repo (GitLab or GitHub — same content)
git clone <repo-url> kong-api-gateway-oss
cd kong-api-gateway-oss
```

## 3. Configure the environment

```bash
cp .env.example .env
# generate a strong password for the internal PostgreSQL:
#   Linux:   openssl rand -hex 24
#   macOS:   openssl rand -hex 24   (or: uuidgen)
# then set it:
sed -i 's/^KONG_PG_PASSWORD=.*/KONG_PG_PASSWORD=<paste-generated-value>/' .env
chmod 600 .env
```

> `scripts/setup.sh` does steps 3–5 automatically, including the
> password generation, if you prefer a one-shot install:
>
> ```bash
> bash scripts/setup.sh
> ```

## 4. Validate and start

```bash
# validate the compose file (no changes made)
docker compose config -q

# build and start (first run builds the echo backend image)
docker compose up -d --build

# watch the stack come up:
docker compose ps
```

Expected: `db` healthy → `migrate` exits 0 (one-shot migrations) →
`kong` healthy → `echo` running.

## 5. Apply the gateway configuration

```bash
bash scripts/configure.sh
```

This creates (idempotently, safe to re-run) the demo services, the 12
routes and the plugin configs described in [CONFIGURATION.md](CONFIGURATION.md).

## 6. Smoke test

```bash
bash scripts/smoke-test.sh
```

Expected output ends with `smoke result: 14 passed, 0 failed`.

## 7. Verify the endpoints

```bash
# gateway health — Admin API /status (database.reachable must be true);
# note the PROXY has no /status route, /test-echo is the end-to-end probe
curl -s http://127.0.0.1:18001/status | python3 -m json.tool | head -12
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/test-echo   # 200

# baseline echo through Kong
curl -s "http://127.0.0.1:18080/test-echo?name=hi"

# authenticated route (X-Api-Key required)
curl -s -X POST http://127.0.0.1:18080/secure-echo \
     -H 'Content-Type: application/json' -H 'X-Api-Key: my-key' \
     -d '{"hello":"world"}'

# ...the same request WITHOUT the key -> 400 controlled JSON error
curl -si -X POST http://127.0.0.1:18080/secure-echo \
     -H 'Content-Type: application/json' -d '{"hello":"world"}'
```

## 8. Run the full test suite (18 mandatory + 9 boundary)

```bash
bash scripts/run-tests.sh
```

## 9. Benchmark

```bash
bash scripts/benchmark.sh
```

Results in `benchmark/results/`. See [TESTING.md](TESTING.md) for the
methodology and the [benchmark README](../benchmark/README.md) if present.

---

### Stopping the stack (without losing data)

```bash
docker compose down          # stop containers; the pgdata volume is KEPT
```

### Full removal (destructive — deletes the database)

```bash
docker compose down -v       # stops containers AND deletes the pgdata volume
```

### Updating to a new Kong version

See the "Version update" section of [CONFIGURATION.md](CONFIGURATION.md).
