# Configuration Reference

## Environment variables (`.env`)

All runtime configuration is driven by environment variables. Copy
`.env.example` to `.env` and adjust. **Never commit `.env`.**

| Variable | Default | Description |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | `kong-gw-oss` | names prefix for ALL Docker resources (containers, volume, network). Use a different value to run a second isolated stack on the same host. |
| `KONG_VERSION` | `3.9.4` | pinned Kong OSS image tag |
| `POSTGRES_VERSION` | `16.6-alpine` | pinned PostgreSQL image tag |
| `KONG_PG_PASSWORD` | — (**required**) | password for the internal PostgreSQL. Strong random value; never the placeholder. |
| `KONG_PROXY_HOST` | `127.0.0.1` | host interface for the Proxy port (loopback by default) |
| `KONG_PROXY_PORT` | `18080` | host port for the Kong Proxy (client traffic) |
| `KONG_ADMIN_HOST` | `127.0.0.1` | host interface for the Admin API — keep loopback |
| `KONG_ADMIN_PORT` | `18001` | host port for the Kong Admin API |
| `ECHO_BACKEND_NAME` | `oss-echo` | marker name reported by the echo backend (used by tests/bench) |

### Example `.env`

```dotenv
COMPOSE_PROJECT_NAME=kong-gw-oss
KONG_VERSION=3.9.4
POSTGRES_VERSION=16.6-alpine
KONG_PG_PASSWORD=6f1a2c...            # strong random (openssl rand -hex 24)
KONG_PROXY_HOST=127.0.0.1
KONG_PROXY_PORT=18080
KONG_ADMIN_HOST=127.0.0.1
KONG_ADMIN_PORT=18001
ECHO_BACKEND_NAME=oss-echo
```

## Service topology

```
                      internal network: ${COMPOSE_PROJECT_NAME}-net
+---------------------------------------------------------------+
|  client                                                       |
|    |  http://127.0.0.1:18080 (Proxy, loopback-only)           |
|    v                                                          |
|  kong (kong:3.9.4)  <----  plugins mounted read-only          |
|    |  admin API 127.0.0.1:18001 (loopback-only)               |
|    |  postgresql://kong:***@<project>-db:5432/kong            |
|    +--> echo:9000  (deterministic test backend, no host port) |
|                                                                 |
|  <project>-db (postgres:16.6-alpine, NO host ports,            |
|                volume ${COMPOSE_PROJECT_NAME}-pgdata)          |
+---------------------------------------------------------------+
```

- Only the Proxy and Admin API publish host ports, both on loopback.
- PostgreSQL is reachable only inside the internal network.
- The echo backend is a deterministic test double (no host port).

## Routes and plugins (created by `scripts/configure.sh`)

| Route | Upstream | Plugins | Purpose |
|---|---|---|---|
| `/test-echo` | `/` | *(none)* | baseline echo (benchmark + control) |
| `/t-req-header` | `/` | `request-transformer` (replace `X-Client-Type`→`modern`) | request header change |
| `/t-req-json` | `/` | `request-transformer` (replace body) | request JSON change |
| `/t-resp-header` | `/` | `response-transformer` (add `X-Gateway-Processed`) | response header add |
| `/fixed-ok` | `/fixed-ok` | `oss-post` (rename `status`→`success`) | response JSON transform |
| `/empty`, `/not-json`, `/echo-error` | as-is | `oss-post` | edge: empty / non-JSON / 500 responses |
| `/t-pre` | `/` | `oss-pre` (auth + correlation id + body rename) | custom pre-processing |
| `/t-post` | `/t-post` | `oss-pre` + `oss-post` (correlation + response rename) | custom post-processing |
| `/secure-echo` | `/` | `oss-pre` (auth: `X-Api-Key` required) | authentication |
| `/combined-echo` | `/combined-echo` | `oss-pre` + `oss-post` (full chain) | combined request+response |

### `oss-pre` configuration fields

| Field | Type | Description |
|---|---|---|
| `required_headers` | array of strings | headers that must be present; missing → 400 controlled JSON error (`{"error":"missing_required_header","header":...,"plugin":"oss-pre"}`) |
| `correlation_id_header` | string | header receiving a generated id (`oss-…`) when the client didn't send one; incoming values are never overwritten |
| `body_rename` | map string→string | top-level JSON request-body key renames (e.g. `customer_id` → `customerId`) |
| `max_body_bytes` | int (0–10 MiB, default 1 MiB) | request bodies above this pass through **untransformed but intact**; `0` disables body handling |

### `oss-post` configuration fields

| Field | Type | Description |
|---|---|---|
| `resp_header_name` / `resp_header_value` | string | response header added on every response (default `X-Oss-Post: processed`) |
| `transform_body` | bool | enable response JSON body key renames |
| `key_rename` | map string→string | top-level response JSON key renames (e.g. `status` → `success`, `backend` → `gateway`) |
| `echo_request_header` | string | request header echoed back as a response header (e.g. the correlation id) |
| `max_body_bytes` | int (default 1 MiB) | response bodies above this pass through **untransformed but complete** (incremental budget, flush-then-pass) |

Documented behavior of `oss-post` body transforms:
- responses on transform routes are framed `Transfer-Encoding: chunked`
  (the plugin clears the upstream `Content-Length` in the ACCESS phase);
- non-JSON, empty and ≥300 (error) responses pass through untouched;
- `response_buffering: on` is set on the transform routes for
  deterministic latency.

## Authentication (Kong OSS)

Kong OSS ships no key-auth plugin (that is an enterprise/DB-less
concern). This release implements API-key **presence** authentication
with the `oss-pre` plugin:

- a route gets `oss-pre` with `required_headers: ["X-Api-Key"]`;
- requests without the header are rejected with a 400 JSON error and
  never reach the upstream;
- the key VALUE is not validated here — for real deployments, put a
  validating plugin (or your auth service) behind/above this layer, or
  use Kong's `key-auth` on a Kong Enterprise / hybrid deployment.

This is the "authentication" capability for an OSS-only stack: it gives
you a hard, controlled, per-route gate with deterministic error
responses, which is what the mandatory test suite exercises.

## Version update (Kong or PostgreSQL)

1. Update the pinned tags in `.env`:

   ```dotenv
   KONG_VERSION=3.9.5        # new pinned version
   ```

2. Re-apply:

   ```bash
   docker compose pull
   docker compose up -d
   ```

   The one-shot `migrate` service runs `kong migrations up`
   automatically on every start (it bootstraps only on a first, empty
   database). Verify afterwards:

   ```bash
   docker compose ps
   bash scripts/configure.sh      # idempotent — re-asserts the layout
   bash scripts/smoke-test.sh
   ```

3. Rollback = restore the old `KONG_VERSION` and `docker compose up -d`
   (Kong migrations support down; the stack stays available in between).

> Upgrade Kong minor/major versions only after reading the Kong
> upgrade notes; the plugin code in `plugins/` uses stable public APIs
> (access + header_filter + body_filter phases).

## Running a second isolated stack

```bash
COMPOSE_PROJECT_NAME=kong-gw-oss-2 KONG_PROXY_PORT=18081 KONG_ADMIN_PORT=18002 \
  docker compose -p kong-gw-oss-2 up -d --build
```

Every container/volume/network is prefixed, so two stacks coexist
without touching each other.
