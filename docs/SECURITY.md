# Security Notes

## Deployment posture (what this release ships)

| Control | How it is enforced |
|---|---|
| **Loopback-only network exposure** | Proxy and Admin API are published on `127.0.0.1` only (`KONG_PROXY_HOST` / `KONG_ADMIN_HOST`). Nothing else publishes a host port. |
| **Admin API isolation** | Admin API is on its own loopback port (18001); it has **no** built-in auth in this release, which is why it must never be bound to a non-loopback interface. |
| **PostgreSQL hidden** | No host port at all; reachable only on the internal Docker network. `POSTGRES_HOST_AUTH_METHOD=trust` is therefore low-risk (it only applies inside the network), but `KONG_PG_PASSWORD` is still set and used by Kong. |
| **Secrets handling** | `KONG_PG_PASSWORD` lives in `.env` (git-ignored, mode 600 recommended). No secrets are baked into images, compose files, or the repo. The trial history was audited: no real credentials in Git history. |
| **Read-only plugin mounts** | `plugins/oss-pre` and `plugins/oss-post` are bind-mounted `read_only` into the Kong container. |
| **Bounded memory for transforms** | Both custom plugins enforce `max_body_bytes` budgets (default 1 MiB, cap 10 MiB). Over-budget bodies pass through **untransformed but complete** — no request/response is dropped, no unbounded buffering. |
| **Controlled errors** | Auth failures return a small, fixed JSON error (`missing_required_header`); stack traces, internal paths and plugin internals are never exposed. |
| **Log hygiene** | Plugins log only neutral operational diagnostics (sizes, phase markers); no header or body values, no secrets. |
| **Image pinning** | `kong:3.9.4`, `postgres:16.6-alpine`, `python:3.12.11-alpine3.21` — all pinned tags for reproducible builds. |
| **Least privilege in images** | The echo backend runs as a non-root user; the bench image is a throwaway client. |

## Custom plugin security model

### `oss-pre` (request pre-processing)
- Required-header check happens **before** the request reaches any
  upstream; the body is not forwarded on failure.
- Body is read into Lua memory **only** when a rename is configured
  AND the declared `Content-Length` is within budget; decoding is
  `pcall`-wrapped (malformed JSON → original body, never a 500).
- Correlation ids are generated per request (`oss-…`); incoming ids
  are preserved, never overwritten.

### `oss-post` (response post-processing)
- Incremental body budget: the moment accumulated bytes exceed
  `max_body_bytes`, buffering stops, the buffered part is flushed, and
  all subsequent chunks pass through untouched (worst-case Lua memory
  = budget + one chunk).
- JSON decode/encode are `pcall`-wrapped; on any failure the original
  body is emitted.
- The correlation id echoed back is the client's own value or a
  plugin-generated one — no server data leaks.

## What this does NOT provide (be explicit)

- **No TLS/terminating encryption.** Put a TLS-terminating reverse
  proxy (or your load balancer) in front; Kong then listens on a
  private interface.
- **No key validation / rate limiting / IP allowlists** out of the box
  on OSS. Add bundled plugins (`rate-limiting`, `ip-restriction`,
  `request-size-limiting`) per route as needed.
- **The 1 MiB body budget is a transform boundary, not a request
  size limit.** If you need to reject large uploads, enable the
  bundled `request-size-limiting` plugin.
- **Not a WAF.** Pair with your upstream app's validation.

## Threat notes / audit findings carried over from the trial

- The internal project history contained no real credentials (verified
  by a full-history grep). One finding outside the repo: a diagnostic
  script (`diag_52.py`, not part of this release) contained a
  hardcoded LiteLLM API key and a master password — **rotate both
  immediately** and keep such keys in a secret manager.
- Internal network IPs (private RFC1918 ranges) that appeared in trial
  files have been stripped from the public release package.

## Recommended hardening checklist for production

1. Set `KONG_ADMIN_HOST=127.0.0.1` and keep it (never 0.0.0.0).
2. Restrict the loopback ports to the operator user / host firewall
   (`iptables`/`nftables` or cloud security groups).
3. Terminate TLS in front; set `KONG_PROXY_LISTEN` behind a private
   interface or a LB health-check path.
4. Rotate `KONG_PG_PASSWORD` regularly; store it in a secrets manager
   and inject it, don't ship `.env` in images.
5. Add `request-size-limiting`, `rate-limiting`, `ip-restriction`
   (bundled OSS plugins) on public routes.
6. Enable Kong's `KONG_ADMIN_GUI_PASSWORD` / use an admin API proxy
   with auth if you expose any admin surface at all.
7. Pin and monitor image tags; run `docker compose pull` + upgrade
   after reviewing Kong release notes.
8. Ship logs to a central collector (they already go to stdout/stderr).
