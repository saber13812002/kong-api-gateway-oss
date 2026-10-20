# Phase 4 — Organizational API Gateway capability matrix (WSO2-like scope)

This matrix maps the feature set of a WSO2-style organizational API
gateway onto **Kong Gateway OSS 3.9.4** and states, for each capability,
whether it is:

| Tag | Meaning |
|---|---|
| **DONE** | Already implemented in this release (tested) |
| **plugin** | Available as a Kong OSS bundled plugin — needs a config (this repo's job) |
| **dev** | Doable on OSS but requires custom code (our `oss-pre`/`oss-post` or a new plugin) |
| **N/A-OSS** | **Not available in Kong OSS** (Enterprise-only or absent) — documented, not hidden |

> **Source of truth:** the plugin catalog below was probed **live** from the
> running Kong OSS 3.9.4 on the release host (server 53) on 2026-10-20 by
> calling `GET /schemas/plugins/<name>` for each candidate
> (`200 = present in this OSS image`, `404 = absent`). It is *not* from
> documentation memory. Version matters: OSS 3.9 includes `correlation-id`
> and `response-ratelimiting` but **not** `request-ratelimiting`, `cache`,
> `client-cert`, `graphql`, `log-stdout`, or `kafka-log`.

---

## 1. Probed plugin catalog (Kong OSS 3.9.4, live from server 53)

**Present (200) in this OSS image:**

```
acl            basic-auth     cors           datadog        file-log
grpc-gateway   grpc-web       hmac-auth      http-log       ip-restriction
jwt            key-auth       ldap-auth      loggly         oauth2
pre-function   post-function  proxy-cache    rate-limiting  request-size-limiting
request-termination  request-transformer  response-ratelimiting  response-transformer
session        syslog         tcp-log        udp-log        aws-lambda
correlation-id acme
```

**Absent (404) in this OSS image (Enterprise-only or not shipped in OSS):**

```
brotli         cache          client-cert    degraphql      forward-proxy
graphql        kubernetes     log-stdout     proxy-cache*   request-ratelimiting
statsd-logger  aws-iam        azure          auth-0         authzen
advanced-mtls-auth  gcp        rdkafka-log    kafka-log      kafka-consumer
rabbitmq-log   mongodb        log-serial-stdout
```

\* `proxy-cache` (present) is the **static-file / response-body cache**
plugin — *not* the full Enterprise response-cache with TTL/invalidation.

**Custom (this repo):** `oss-pre`, `oss-post` (Lua, mounted read-only).

**Currently configured on the live gateway (server 53):**
`oss-pre`, `oss-post`, `request-transformer`, `response-transformer`.

---

## 2. WSO2-like feature → Kong OSS mapping

| # | WSO2-style capability | OSS status | Kong mechanism / notes |
|---|---|---|---|
| 1 | API + route CRUD (management UI) | **DONE** | `panel/manage.py` (Phase 3): services/routes/consumers/plugins/upstreams, RBAC, CSRF, audit, pre-change backup. Behind 443 gate on 52, loopback on 53. |
| 2 | Upstream + target management | **DONE** (partial) | OSS `upstreams` + `targets` CRUD is in the UI. **Active health checks are Enterprise** → on OSS, targets are static; passive failure handled by LB/retry only. *Documented limitation.* |
| 3 | API key auth (consumers) | **plugin** | `key-auth` (present). Enable via `configure.sh` / UI. Consumers managed in UI. |
| 4 | Basic auth | **plugin** | `basic-auth` (present). |
| 5 | HMAC auth | **plugin** | `hmac-auth` (present). |
| 6 | JWT auth | **plugin** | `jwt` (present). |
| 7 | OAuth2 (authorization-code, etc.) | **plugin** | `oauth2` (present) — provides token endpoints. |
| 8 | mTLS / client-cert auth | **N/A-OSS** | `client-cert` **absent** in OSS (Enterprise). Workaround: TLS-terminate upstream with mTLS, or `ldap-auth`/`jwt` for cert-free identity. *Documented limitation.* |
| 9 | LDAP auth | **plugin** | `ldap-auth` (present). |
| 10 | ACL / scope-based authorization | **plugin** | `acl` (present) — pair with an auth plugin; `key-auth`+`acl` is the standard OSS combo. |
| 11 | Request rate limiting (per consumer) | **plugin** | `rate-limiting` (present). **Single-DB-node semantics** — the counter lives in the DB, so multiple data-plane nodes do not coordinate. *Documented limitation.* |
| 12 | Response rate limiting | **plugin** | `response-ratelimiting` (present in OSS 3.9). `request-ratelimiting` is **absent** — only response-shaping is available. |
| 13 | Request-size limiting | **plugin** | `request-size-limiting` (present). |
| 14 | Request / response header + body transform | **DONE** + **plugin** | `request-transformer` + `response-transformer` (bundled, in use) and our `oss-pre`/`oss-post` for JSON body key-rename and header echo. |
| 15 | Correlation / request id | **DONE** + **plugin** | `oss-pre` emits `X-Correlation-Id`; the bundled `correlation-id` plugin is also available (OSS 3.9) as an alternative. |
| 16 | Versioning (v1/v2 side-by-side) | **dev** (pattern) | No first-class version object in OSS. Standard pattern: separate `service`+`route` per version, host/path-based (`/v1/...`, `/v2/...`). Documented in this matrix + API docs. |
| 17 | Traffic shaping / canary / weighted | **dev** | OSS `upstreams` supports **target weights** (passive, no health signal). True canary/active LB = Enterprise. *Documented limitation.* |
| 18 | IP allow/deny | **plugin** | `ip-restriction` (present). |
| 19 | Request termination (blocking) | **plugin** | `request-termination` (present). |
| 20 | CORS | **plugin** | `cors` (present). |
| 21 | gRPC pass-through / gRPC-web | **plugin** | `grpc-gateway`, `grpc-web` (present). |
| 22 | AWS Lambda integration | **plugin** | `aws-lambda` (present). |
| 23 | Observability: structured logs to sink | **plugin** | `http-log`, `file-log`, `tcp-log`, `udp-log`, `syslog`, `datadog`, `loggly` (all present). `kafka-log`/`rdkafka-log`/`log-stdout` **absent** in OSS 3.9. |
| 24 | Observability: metrics | **dev** | No built-in Prometheus plugin in OSS. `http-log`/`file-log` to a collector, or `pre-function`/`post-function` to emit. Documented. |
| 25 | Caching (response) | **dev** (partial) | `proxy-cache` present (static/response-body). Full TTL/invalidation response-cache = Enterprise. *Documented limitation.* |
| 26 | Response compression (gzip) | **N/A-OSS** | No gzip/brotli plugin in OSS (`brotli` absent). Handled by the fronting load balancer / nginx. *Documented limitation.* |
| 27 | WAF / bot protection | **N/A-OSS** | Not in OSS (Enterprise `waf` / Auth0). Mitigate with `ip-restriction` + upstream WAF. *Documented limitation.* |
| 28 | Developer portal / API catalog | **N/A-OSS** | No portal in OSS. Static OpenAPI page shipped instead (item 30). |
| 29 | Usage analytics / metering dashboard | **dev** | No built-in analytics. Aggregate `http-log`/`file-log` externally. *Documented limitation.* |
| 30 | API documentation (static OpenAPI page) | **dev** → **DONE this phase** | `scripts/gen-api-docs.py` renders a static HTML catalog from the live route inventory (no Swagger UI dep); curl try-out examples per route. |
| 31 | Config as code / export-import (GitOps) | **dev** → **DONE this phase** | `scripts/export.sh` (declarative decK-style file) + `scripts/import.sh` (apply a file). Round-trip tested on 53. |
| 32 | Pre/post request scripting | **plugin** | `pre-function` / `post-function` (present) — plus our `oss-pre`/`oss-post`. |
| 33 | AI / LLM gateway (OpenAI-compatible) | **dev** | Out of scope for stock OSS — Phase 5 custom (`ai-gw` service). Boundary: Kong enforces auth/rate-limit/correlation/metadata; model routing stays in the AI tier. |

**Legend for "documented limitation":** OSS-only behavior that a WSO2
deployment would expect but Kong OSS does not provide (active health
checks, request-ratelimiting, mTLS client-cert, full response cache,
gzip, WAF, portal, analytics, multi-node rate-limit coordination).
Each is called out inline above and summarized in §3.

---

## 3. OSS limitations (explicit — do not assume these exist)

1. **No active upstream health checks / passive LB intelligence** —
   `upstreams` targets are static (weights only). Kong Enterprise adds
   active health checks.
2. **`rate-limiting` is single-node** — the rate counter is stored in the
   DB, so a multi-data-plane deployment does not share a global counter.
   Fine for a single DB-mode node (this deployment).
3. **No `request-ratelimiting`** (only `response-ratelimiting` in OSS 3.9).
4. **No mTLS client-cert auth** (`client-cert` Enterprise).
5. **No full response cache** (only `proxy-cache` static/body cache).
6. **No gzip/brotli compression plugin** — front the gateway with an
   nginx/load-balancer that compresses.
7. **No WAF / developer portal / built-in analytics** in OSS.
8. **No `kafka-log` / `log-stdout` / `statsd-logger`** in OSS 3.9.
9. **GraphQL plugins absent** (`graphql`, `degraphql`).

---

## 4. What this phase delivers (OSS-doable set)

- **Static OpenAPI catalog** — `scripts/gen-api-docs.py` (HTML, curl
  examples, generated from the live route inventory).
- **Config GitOps** — `scripts/export.sh` → declarative
  `_export/kong-gateway.yml` (services, routes, plugins, consumers);
  `scripts/import.sh` → apply that file. Idempotent, round-trip tested.
- **This matrix** — `docs/CAPABILITY_MATRIX.md` (this file).

Wiring of the individual bundled auth plugins (key-auth, hmac-auth, jwt,
basic-auth, oauth2, acl, ip-restriction, request-size-limiting,
rate-limiting, response-ratelimiting) is a **configuration** exercise on
top of `configure.sh`; each is `plugin`-available and can be enabled per
service/route through the Phase-3 management UI or a declarative file.
They are intentionally not force-enabled on the demo routes so the test
suite stays deterministic; the UI/export path is the supported way to
turn them on.
