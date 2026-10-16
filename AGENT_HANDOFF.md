# AGENT HANDOFF — Kong OSS Gateway Final Release

Context-safety snapshot (written 2026-10-16, mid-Phase-4). Phases 1–3 are
COMPLETE and fully verified on the internal operations host. Phases 5–6
are pending explicit
user approval (public push) / reporting-only (cleanup).

## Verified state on the operations host

> Public-release note: concrete host names, paths and internal URLs have
> been replaced with placeholders. The exact values live only in the
> internal operations notes, never in this repository.

- Remote release path: `<ops-user>/kong-api-gateway-oss` (identical to
  local `release/kong-api-gateway-oss/`)
- Compose project: `kong-gw-oss` — containers `kong-gw-oss-{kong,db,echo}`
  + one-shot `migrate`/`bench`; loopback ports **18080** (proxy) /
  **18001** (admin); Kong **3.9.4**, PostgreSQL **16.6-alpine**
- Plugins bind-mounted **read-only** into
  `/usr/local/share/lua/5.1/kong/plugins/oss-{pre,post}`
- **ALL TESTS GREEN (re-verified after final code state):**
  - `scripts/setup.sh` idempotent re-run → "setup complete" (port
    pre-flight exempts our own container)
  - `scripts/smoke-test.sh` → **14/14**
  - `scripts/run-tests.sh` → **18/18** (T01–T18) + **9/9** (B1–B9) boundary
  - `scripts/security-test.sh` → **11/11**
  - `scripts/restart-test.sh` standalone → **6/6**
  - README "Try the demo endpoints" curls 1–6 → all match documented
    behavior (auth 400 JSON, rename, `X-Oss-Post`, chunked framing,
    `X-Correlation-Id: demo-1` echo)
  - `scripts/benchmark.sh` (3×100, concurrency 1, adaptive warmup):
    direct mean **1.017 ms** (rps 958), via-Kong mean **1.427 ms**
    (rps 674), **overhead +0.410 ms mean / +0.546 ms p95**, 0 failures.
    Artifacts: `benchmark/results/`
- Suite latency sample: T15 p50 1.423 ms / p95 2.306 ms; T16 0/200 errors.

## Live Admin API entity IDs (53)

Services (all `host=echo:9000`):
`test-echo-svc=df31a863-23d0-4687-93f2-fd996ea51d8e`
`t-req-header-svc=2960747a-7865-459a-b57f-a60e410fc01d`
`t-req-json-svc=192b1c8e-074a-4f43-8e60-26f4b1795153`
`t-resp-header-svc=1334d9d7-d01a-4695-8194-c532f9f8a842`
`t-resp-json-svc=ee7e62b8-99fe-40c7-ab5a-ce64c4cf11d9`
`t-resp-edge-svc=ac66e2e8-beee-46ec-b348-2812a3f15d35`
`t-pre-svc=87e566a3-c264-4f16-961d-4462ab632543`
`t-post-svc=5a7df360-b47e-4c62-b292-1f1396b1caa2`
`secure-echo-svc=55433b6b-02cc-420e-9ee0-f929fedf122a`
`combined-svc=9f33f6f1-86d2-4c9b-949f-e79b04196fb1`

Routes (12): `test-echo-route=4caf2e9b-…`, `t-req-header-route=05435735-…`,
`t-req-json-route=aca05b7c-…`, `t-resp-header-route=77571769-…`,
`t-resp-json-route=3210339e-…` (`/fixed-ok`), `t-resp-edge-empty=fc3e30b3-…`
(`/empty`), `t-resp-edge-notjson=12974e5b-…` (`/not-json`),
`t-resp-edge-error=fad5916d-…` (`/echo-error`), `t-pre-route=9b42e937-…`
(`/t-pre`), `t-post-route=53f471cd-…` (`/t-post`),
`secure-echo-route=c181e473-…` (`/secure-echo`),
`combined-route=41517880-…` (`/combined-echo`).

Plugins (11, all service-linked via nested endpoints):
`9a528fb1-…` (request-transformer, t-req-header),
`f7bcd43d-…` (request-transformer remove+`add.body` `"key:value"` no-space,
t-req-json), `55fe87c8-…` (response-transformer, t-resp-header),
`3721fe0a-…` (oss-post, t-resp-json), `851337f6-…` (oss-post, t-resp-edge),
`6ebf8a0c-…` (oss-pre, t-pre), `756750a2-…` (oss-pre, t-post),
`232133e1-…` (oss-post, t-post), `485105bb-…` (oss-pre, secure-echo),
`346089dc-…` (oss-pre, combined), `1cce3dde-…` (oss-post, combined).

## Kong 3.9.4 API contracts verified from container source

- Raw request body replacement in `access`:
  `kong.service.request.set_raw_body(str)` + explicit
  `kong.service.request.set_header("Content-Length", #str)` (same as
  bundled request-transformer). `set_body(str)` → "args must be a table".
- Response headers: no `kong.service.response.set_header`; use
  `header_filter` + `ngx.header[name] = value`;
  `ngx.header["Content-Length"] = nil` forces chunked framing.
- `kong.request.get_header` (there is no `ngx.req.get_header` in plugin
  context); handler methods receive `conf` as a parameter.
- request-transformer `transform_json_body`: `replace.body` overwrites
  **existing** keys only; `add.body` sets **absent** keys only (hence
  remove + add for key replacement); pair parser
  `^([^:]+):*(.-)$` keeps the raw remainder → **no space after colon**.
- Admin `GET /status` → `{database, memory, server}`; health signal is
  `database.reachable == true`.
- Admin full-update semantics: top-level PUT without `service` NULLS the
  relation → always use nested
  `PUT /services/{id}/routes/{rid}` and `PUT /services/{id}/plugins/{pid}`.
- After a plugin PUT, one worker may briefly serve stale config
  (cluster-event propagation) — verify live config / re-run before
  concluding a bug.
- After `docker restart kong`, each worker needs its own cache/DNS warmup
  (first request can take ~8 s) → use probe-until-200 warmup loops.
- Docker `NetworkSettings.Ports` `"port/tcp": null` = EXPOSED but NOT
  published (safe); a violation is a non-null `HostPort`. On the shared
  operations host, fixed host ports may be owned by unrelated containers
  (e.g. `mock-service`) — judge isolation by
  the container's own port map, never by probing a host port.

## Environment / tooling notes (Windows side)

- CRLF guard after every local edit: `python fix-crlf.py <paths>`.
- Transfer pattern:
  `cd release && tar -cf - kong-api-gateway-oss/<sub> | ssh <ops-host> "cd <remote-dir> && tar -xf -"`
- Run remote scripts via pipe (nested ssh quoting breaks in cmd.exe):
  `type X.sh | ssh <ops-host> "cat > /tmp/X.sh && bash /tmp/X.sh 2>&1"`
- Deploy helper (reusable): `diag-kong47.sh` at the workspace root —
  luajit parse-check of all plugin files, `bash -n` on scripts, kong
  restart, admin-200 wait, /test-echo warmup.
- **NEVER TOUCH** on the shared operations host: ragportal_*, taghrir_*,
  eiis_*, mesbah_*,
  vllm-*, tyk-*, open-webui, mock-*, surfsense-*, neo4j_db, qdrant,
  csghub-omnibus, iranseda-*, langgraph_app, dcgm-exporter, promtail,
  node-exporter, ollama, i3-rdp, rdp-desktop, h200-public-tunnel,
  heuristic_mclean.
- The second internal server was **unreachable** from the build machine
  in Phase 1/6 (no ssh target available); it is referenced in this file
  only via its GitLab repository URL (placeholder above).

## Phase status

- **Phase 1 (audit)** — PASS. No real secrets in repo/Git history;
  internal IPs inventoried and stripped from this public package;
  `push-to-gitlab.ps1` and `step4/remote_exec.py` audited (no embedded
  credentials; host/user in
  env/args only).
- **Phase 2 (release package)** — PASS. Standalone, env-driven, no
  organizational IP required; syntax-validated, CRLF-normalized.
- **Phase 3 (isolated tests + clean install on the operations host)** —
  PASS. Numbers
  above; every failure found was fixed in-repo and re-run to green.
- **Phase 4 (final README + verified commands)** — PASS (this snapshot).
  Every README/INSTALL command executed on the operations host; docs
  synced with
  verified semantics; setup.sh port pre-flight + /test-echo probe fixed.
- **Phase 5 (Git readiness)** — PENDING approval. Targets: the internal
  GitLab repository (`<internal-gitlab-host>:81/common/kong-gateway.git`)
  + GitHub `https://github.com/saber13812002/kong-api-gateway-oss.git`,
  both on `main`. No force push. **Public push needs explicit user
  approval.** Pre-push: final secrets audit of tree + history, `.env`
  gitignored, no credentials in URLs.
- **Phase 6 (cleanup proposal)** — PENDING (report only). Inventory of
  the two internal servers' resources + cleanup/recovery plan; **no
  deletion without explicit user approval**; the second server was
  inaccessible from the build machine.

## Local scratch files to delete before handover

`diag-kong*.sh` (1–53), `verify-lua.sh`, `fix-crlf.py`, `crlf-report.txt`
at the workspace root (outside the release folder — never committed).
