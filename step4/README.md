# STEP 4 — Kong OSS Pre/Post Transformation (s52 trial)

Isolated, idempotent, loopback-only. All work targets the `kong-gw-trial`
stack only (containers: `kong-gw-trial-{db,migrate,kong,echo}`).
The baseline `/test-echo` route is **never modified**; `tests.py` snapshots
its Admin API object before and after the whole run to prove it.

## Scenarios (7) and how each is implemented

| # | Scenario | Plugin used | Mechanism |
|---|----------|-------------|-----------|
| 1 | Request header `X-Client-Type: legacy → modern` | OSS `request-transformer` | `config.replace.headers` (ACCESS phase, same-request) |
| 2 | Request JSON body `customer_id → customerId` | OSS `request-transformer` | `config.replace.body` (top-level key replacement; body replaced wholesale) |
| 3 | Response header `X-Gateway-Processed: kong` | OSS `response-transformer` | `config.add.headers` |
| 4 | Response JSON `{"status":"ok","data":{"id":123}} → {"success":"ok","data":{"id":123}}` | **custom `step4-post`** (Lua) | `body_filter` accumulation + top-level key rename; deterministic upstream body from echo `/fixed-ok` |
| 5 | Custom pre-processing: required-header validation, correlation ID, body rename | **custom `step4-pre`** (Lua) | ACCESS: 400 JSON error; `set_header` correlation id (never overwrites); `set_raw_body` after key rename |
| 6 | Custom post-processing: response header + body transform | **custom `step4-pre`+`step4-post`** | correlation generated in pre, echoed in post (`ngx.ctx`); body renamed `backend→gateway` |
| 7 | Combined POST scenario (both directions) | both custom plugins | request: rename+correlation → upstream `/combined-echo` (proves transformed body); response: `status→success` + correlation echoed back |

Routes (all on Kong proxy `127.0.0.1:18080`, isolated from `/test-echo`):

```
/t-req-header   strip     t-req-header-svc   -> echo /          (scenario 1)
/t-req-json     strip     t-req-json-svc     -> echo /          (scenario 2)
/t-resp-header  strip     t-resp-header-svc  -> echo /          (scenario 3)
/fixed-ok       keep      t-resp-json-svc    -> echo /fixed-ok  (scenario 4, deterministic body)
/empty /not-json /echo-error  keep   t-resp-edge-svc -> echo (scenario 4 edge cases)
/t-custom-pre   strip     t-custom-pre-svc   -> echo /          (scenario 5)
/t-custom-post  keep      t-custom-post-svc  -> echo /          (scenario 6)
/combined-echo  keep      t-combined-svc     -> echo /combined-echo (scenario 7)
```

`keep` = `strip_path: false` (upstream path preserved, required for the
deterministic endpoints).

## Custom Lua plugins (OSS-compatible, no enterprise features)

Source: `plugins/step4-pre/`, `plugins/step4-post/` (mounted **read-only**
per-plugin into `/usr/local/share/lua/5.1/kong/plugins/`; bundled plugins
stay visible — a single dir mount would have shadowed them).

Activation: `KONG_PLUGINS: bundled,step4-pre,step4-post` on `kong-gw`.
Re-activate after editing a plugin: `docker compose up -d kong-gw`
(the bind mount is read-only, so editing host files requires Kong restart;
`kong reload` is NOT used — it does not re-read plugin modules).

### `step4-pre` (ACCESS phase, PRIORITY 500)
1. `required_headers` — missing/empty header ⇒ `400` JSON error
   `{"error":"missing_required_header","header":...,"plugin":"step4-pre"}`
   (upstream never called).
2. `correlation_id_header` — generated `step4-<time>-<8hex>-<8hex>` when
   missing; **existing value is preserved** (proven by test S5-1/S7-1);
   stored in `ngx.ctx.step4_correlation_id` for the post plugin.
3. `body_rename` — POST/PUT/PATCH JSON bodies: top-level key renames via
   `cjson.safe` + `kong.service.set_raw_body` (adjusts Content-Length
   correctly). Non-JSON or unchanged bodies pass through **byte-identical**.

### `step4-post` (ACCESS + body_filter, PRIORITY -500)
1. ACCESS: `kong.service.response.set_header(...)` (same mechanism as the
   bundled `response-transformer`); echoes the correlation id when
   `echo_request_header` is set.
2. If a body transform is configured, ACCESS also calls
   `kong.service.response.clear_header("Content-Length")`.

### Response buffering / Content-Length / streaming / memory (documented)
- **Why CL is cleared in ACCESS**: nginx sends response *headers* to the
  client in the header-filter stage, **before** any `body_filter` runs.
  Fixing Content-Length inside `body_filter` is therefore impossible in
  Kong OSS (the header is already on the wire). Clearing it in ACCESS
  forces `Transfer-Encoding: chunked` client framing, so the body filter
  may emit a transformed body of any length. Consequence (accepted,
  documented): **transform routes always answer chunked** — including
  pass-through (empty / non-JSON / 500) responses.
- **Buffering**: the body is accumulated in Lua (one `parts` array),
  chunks swallowed until the final one, then replaced wholesale.
  `response_buffering: "on"` (route option) is set on all transform
  routes so nginx also holds the full upstream response in its proxy
  buffers — deterministic client latency, no partial writes.
- **Streaming limitation**: for unbuffered (streaming) upstream responses
  the plugin still works (it buffers in Lua) but client latency stretches
  to the upstream stream end — there is no way to rewrite a streamed body
  in real time in OSS. This is the core OSS limitation vs enterprise
  response-body transformation features.
- **Safety**: transform only when `transform_body=true`, a rename is
  configured, upstream `status < 300`, `Content-Type` contains `json`, and
  body ≤ `max_body_bytes` (default 1 MiB). Empty bodies → re-emitted as
  empty; non-JSON / errors / oversize → re-emitted **untouched**. All in
  `pcall`, so a decode error can never take the worker down.
- **Memory bound**: ≤ `max_bytes` + one transient proxy-buffer chunk.

## Execution (on s52, from ~/kong-gateway)

```
bash step4/run.sh
```
= pre-state → `deploy.sh` (rebuild echo v1.1, recreate kong w/ mounts,
verify deterministic endpoints directly in the echo container) →
`configure.sh` ×2 (idempotency proof: 2nd run must be all PUTs) →
`tests.py` (19 real HTTP cases) → post-state (container count, baseline
route, public listener set).

`bash step4/capabilities.sh` → Task A capability dump
(`results/capabilities.txt`).

Artifacts written: `step4/results/step4-results.json` (raw per-case
data), `step4/results/step4-report.txt` (human report),
`step4/results/raw/<case>.json`, `step4/results/capabilities.txt`.

## Reproducibility
- Kong 3.9.4 (pinned), echo image built from pinned
  `python:3.12.11-alpine3.21`, all plugin/config sources in this tree.
- Every Admin API operation is an upsert or find-or-create: re-running
  `configure.sh` is safe and proven (run #2).
- No public ports are opened; all test routes live on the loopback proxy
  (127.0.0.1:18080) / Admin (127.0.0.1:18001) only.
