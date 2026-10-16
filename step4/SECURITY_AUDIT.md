# Security & Robustness Audit — custom plugins (pre GitHub public release)

Scope: `step4/plugins/step4-pre/handler.lua`, `step4/plugins/step4-post/handler.lua`
and their `schema.lua`. Reviewed for: injection, information disclosure,
memory/DoS, JSON handling correctness, and deployment hygiene.

## Findings and resolutions

### 1. Request body read was unbounded (step4-pre) — FIXED
`read_full_body()` previously read the **entire** request body into Lua
memory before the JSON check, on every POST/PUT/PATCH where a rename was
configured. A client could send a multi-MB body and force the worker to
buffer it all, exhausting Lua heap / worker memory (slow-loris +
body-bloat DoS).

Fix: the body is only read when (a) a rename is configured, (b) the method
carries a body, and (c) the declared `Content-Length` is within
`max_body_bytes` (new config field, default **1 MiB**, range 0–10 MiB,
`0` disables body handling entirely). A double check (`#body <= max_bytes`)
covers chunked/lying Content-Length. Oversized bodies pass through
**untransformed** (never dropped, never error).

### 2. Response body accumulation was not incrementally bounded (step4-post) — FIXED
The `body_filter` accumulated **all** chunks into `st.parts` and only
compared `#body > st.max_bytes` at the very end. A large JSON response
streamed slowly could therefore keep growing the Lua table far past the
intended 1 MiB cap before being discarded.

Fix: `st.total` is incremented per chunk; once `st.total > st.max_bytes`
the plugin sets `st.over_budget`, flushes the buffered part and passes all
subsequent chunks through untouched (no transform). Worst-case Lua memory
for one request is now `max_body_bytes + 1 chunk` (one nginx proxy buffer,
default ≤ 4 KiB × 2), not unbounded.

### 3. JSON decode/encode wrapped in `pcall` — VERIFIED (pre, hardening applied)
- step4-post already wrapped the whole decode→rename→encode in `pcall`;
  malformed / non-JSON / circular-ish input falls back to the original
  body (no 500, no crash).
- step4-pre now also wraps `cjson.decode` and `cjson.encode` in `pcall`
  (previously bare calls). Any decode/encode failure → original body
  passes through with an ERR log, no error response to the client.

### 4. Information disclosure — VERIFIED CLEAN
- No secrets, PII, DB DSN, or hostnames are logged. Only neutral
  operational strings ("cannot open body file", "failed to re-encode").
- The echoed response header (`echo_request_header`) returns only the
  **client's own** correlation header or a value the plugin generated
  (`step4-<time>-<random>`); no server-side data.
- The 400 "missing_required_header" error reveals only the header **name**
  (which the admin configured), not its value or internal routing.
- Repo hygiene: `.env` is git-ignored; only `.env.example` (a placeholder)
  is tracked. No internal IPs, passwords, or tokens in committed files.

### 5. Injection / code execution — VERIFIED CLEAN
- No `os.execute`, no `loadstring`, no dynamic `require`, no shell.
- Body "transform" is a pure table-key rename on decoded JSON (top-level
  keys only) — it cannot execute payload content. `cjson.safe` is used
  (returns nil on error instead of raising).
- Header names/values from config are used only as header names via the
  Kong API; header **values** are set as opaque strings (no interpolation
  into any script or template).

### 6. Memory lifecycle — VERIFIED
- `ngx.ctx` state is per-request and auto-freed at request end.
- step4-post nils `st.parts` after the final chunk; step4-pre holds no
  cross-phase state.
- With the two bounds above, per-request Lua memory is now bounded by
  `2 × max_body_bytes` worst case (request + response), each ≤ 1 MiB
  default.

## Accepted, documented limitations (not vulnerabilities)
- **Non-JSON request bodies** are passed through untransformed (no rename).
  Documented; the trial backends always send JSON.
- **Oversized bodies** bypass transformation (pass through intact). This is
  the safe failure mode.
- **Response-transform routes are always chunked** (Content-Length cleared
  in access phase so the body filter can change length). Documented in the
  handler header; a real performance/compat consideration, not a security
  issue.
- **Correlation id entropy** uses `math.random` seeded once per worker.
  Sufficient for a trace id (not a security token). If it ever becomes a
  bearer/security value, switch to `ngx.now()` + counter or a CSPRNG.

## Verdict
Both plugins are safe to publish. The two memory-bounds fixes are the only
changes; all other concerns verified clean. Recommend re-running
`step4/run.sh` (19 e2e tests) after deploy to confirm the hardened paths
still pass (they should — behavior for in-budget bodies is unchanged).
