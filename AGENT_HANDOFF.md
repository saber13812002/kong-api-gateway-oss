# AGENT HANDOFF ΓÇö Kong OSS Gateway Final Release

Context-safety snapshot (written 2026-10-16, mid-Phase-4). Phases 1ΓÇô3 are
COMPLETE and fully verified on the internal operations host. Phases 5ΓÇô6
are pending explicit
user approval (public push) / reporting-only (cleanup).

## Verified state on the operations host

> Public-release note: concrete host names, paths and internal URLs have
> been replaced with placeholders. The exact values live only in the
> internal operations notes, never in this repository.

- Remote release path: `<ops-user>/kong-api-gateway-oss` (identical to
  local `release/kong-api-gateway-oss/`)
- Compose project: `kong-gw-oss` ΓÇö containers `kong-gw-oss-{kong,db,echo}`
  + one-shot `migrate`/`bench`; loopback ports **18080** (proxy) /
  **18001** (admin); Kong **3.9.4**, PostgreSQL **16.6-alpine**
- Plugins bind-mounted **read-only** into
  `/usr/local/share/lua/5.1/kong/plugins/oss-{pre,post}`
- **ALL TESTS GREEN (re-verified after final code state):**
  - `scripts/setup.sh` idempotent re-run ΓåÆ "setup complete" (port
    pre-flight exempts our own container)
  - `scripts/smoke-test.sh` ΓåÆ **14/14**
  - `scripts/run-tests.sh` ΓåÆ **18/18** (T01ΓÇôT18) + **9/9** (B1ΓÇôB9) boundary
  - `scripts/security-test.sh` ΓåÆ **11/11**
  - `scripts/restart-test.sh` standalone ΓåÆ **6/6**
  - README "Try the demo endpoints" curls 1ΓÇô6 ΓåÆ all match documented
    behavior (auth 400 JSON, rename, `X-Oss-Post`, chunked framing,
    `X-Correlation-Id: demo-1` echo)
  - `scripts/benchmark.sh` (3├ù100, concurrency 1, adaptive warmup):
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

Routes (12): `test-echo-route=4caf2e9b-ΓÇª`, `t-req-header-route=05435735-ΓÇª`,
`t-req-json-route=aca05b7c-ΓÇª`, `t-resp-header-route=77571769-ΓÇª`,
`t-resp-json-route=3210339e-ΓÇª` (`/fixed-ok`), `t-resp-edge-empty=fc3e30b3-ΓÇª`
(`/empty`), `t-resp-edge-notjson=12974e5b-ΓÇª` (`/not-json`),
`t-resp-edge-error=fad5916d-ΓÇª` (`/echo-error`), `t-pre-route=9b42e937-ΓÇª`
(`/t-pre`), `t-post-route=53f471cd-ΓÇª` (`/t-post`),
`secure-echo-route=c181e473-ΓÇª` (`/secure-echo`),
`combined-route=41517880-ΓÇª` (`/combined-echo`).

Plugins (11, all service-linked via nested endpoints):
`9a528fb1-ΓÇª` (request-transformer, t-req-header),
`f7bcd43d-ΓÇª` (request-transformer remove+`add.body` `"key:value"` no-space,
t-req-json), `55fe87c8-ΓÇª` (response-transformer, t-resp-header),
`3721fe0a-ΓÇª` (oss-post, t-resp-json), `851337f6-ΓÇª` (oss-post, t-resp-edge),
`6ebf8a0c-ΓÇª` (oss-pre, t-pre), `756750a2-ΓÇª` (oss-pre, t-post),
`232133e1-ΓÇª` (oss-post, t-post), `485105bb-ΓÇª` (oss-pre, secure-echo),
`346089dc-ΓÇª` (oss-pre, combined), `1cce3dde-ΓÇª` (oss-post, combined).

## Kong 3.9.4 API contracts verified from container source

- Raw request body replacement in `access`:
  `kong.service.request.set_raw_body(str)` + explicit
  `kong.service.request.set_header("Content-Length", #str)` (same as
  bundled request-transformer). `set_body(str)` ΓåÆ "args must be a table".
- Response headers: no `kong.service.response.set_header`; use
  `header_filter` + `ngx.header[name] = value`;
  `ngx.header["Content-Length"] = nil` forces chunked framing.
- `kong.request.get_header` (there is no `ngx.req.get_header` in plugin
  context); handler methods receive `conf` as a parameter.
- request-transformer `transform_json_body`: `replace.body` overwrites
  **existing** keys only; `add.body` sets **absent** keys only (hence
  remove + add for key replacement); pair parser
  `^([^:]+):*(.-)$` keeps the raw remainder ΓåÆ **no space after colon**.
- Admin `GET /status` ΓåÆ `{database, memory, server}`; health signal is
  `database.reachable == true`.
- Admin full-update semantics: top-level PUT without `service` NULLS the
  relation ΓåÆ always use nested
  `PUT /services/{id}/routes/{rid}` and `PUT /services/{id}/plugins/{pid}`.
- After a plugin PUT, one worker may briefly serve stale config
  (cluster-event propagation) ΓÇö verify live config / re-run before
  concluding a bug.
- After `docker restart kong`, each worker needs its own cache/DNS warmup
  (first request can take ~8 s) ΓåÆ use probe-until-200 warmup loops.
- Docker `NetworkSettings.Ports` `"port/tcp": null` = EXPOSED but NOT
  published (safe); a violation is a non-null `HostPort`. On the shared
  operations host, fixed host ports may be owned by unrelated containers
  (e.g. `mock-service`) ΓÇö judge isolation by
  the container's own port map, never by probing a host port.

## Environment / tooling notes (Windows side)

- CRLF guard after every local edit: `python fix-crlf.py <paths>`.
- Transfer pattern:
  `cd release && tar -cf - kong-api-gateway-oss/<sub> | ssh <ops-host> "cd <remote-dir> && tar -xf -"`
- Run remote scripts via pipe (nested ssh quoting breaks in cmd.exe):
  `type X.sh | ssh <ops-host> "cat > /tmp/X.sh && bash /tmp/X.sh 2>&1"`
- Deploy helper (reusable): `diag-kong47.sh` at the workspace root ΓÇö
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

- **Phase 1 (audit)** ΓÇö PASS. No real secrets in repo/Git history;
  internal IPs inventoried and stripped from this public package;
  `push-to-gitlab.ps1` and `step4/remote_exec.py` audited (no embedded
  credentials; host/user in
  env/args only).
- **Phase 2 (release package)** ΓÇö PASS. Standalone, env-driven, no
  organizational IP required; syntax-validated, CRLF-normalized.
- **Phase 3 (isolated tests + clean install on the operations host)** ΓÇö
  PASS. Numbers
  above; every failure found was fixed in-repo and re-run to green.
- **Phase 4 (final README + verified commands)** ΓÇö PASS (this snapshot).
  Every README/INSTALL command executed on the operations host; docs
  synced with
  verified semantics; setup.sh port pre-flight + /test-echo probe fixed.
- **Phase 5 (Git readiness)** ΓÇö Published to GitHub `main` (2026-10-16):
  a merge commit combining the final release (`d699447`, working tree of
  `main`) with the previously published trial history (no force push;
  default-branch switch to `main` is a one-click owner action).
  Internal GitLab target (see internal ops notes): strategy pending
  owner decision (branch vs. new project vs. merge). **No force push
  ever; no credentials in URLs.**
- **Phase 6 (cleanup proposal)** ΓÇö PENDING (report only). Inventory of
  the two internal servers' resources + cleanup/recovery plan; **no
  deletion without explicit user approval**; the second server was
  inaccessible from the build machine.

## Local scratch files to delete before handover

`diag-kong*.sh` (1ΓÇô53), `verify-lua.sh`, `fix-crlf.py`, `crlf-report.txt`
at the workspace root (outside the release folder ΓÇö never committed).

---

## 8. LIVE DEPLOYMENT STATUS (as of 2026-10-17)

### 53 (172.20.1.53, GPU) ΓÇö "kong-gw-oss" stack
- Containers up: kong-gw-oss-kong (127.0.0.1:18080->8000, 127.0.0.1:18001->8001), kong-gw-oss-echo, kong-gw-oss-db.
- Kong: 10 routes, 2 services, oss-pre/oss-post plugins on /oss/echo.
- Admin API: 127.0.0.1:18001 (loopback-only) + LAN proxy http://172.20.1.53:18002 (basic auth).
- Auth users (nginx basic auth): admin / drsoheili.
- Repo at ~/kong-api-gateway-oss == github main (37d0d92).

### 52 (172.20.1.52, no GPU) ΓÇö "kong-gw-trial" stack
- Containers up: kong-gw-trial-kong (127.0.0.1:18080, 127.0.0.1:18001), kong-gw-trial-echo, kong-gw-trial-db, plus kong-admin-auth-52 (LAN proxy on 0.0.0.0:8001, basic auth).
- Public domain: https://kong.ai.ismc.ir -> BaoTa nginx (52) -> 127.0.0.1:18001, basic auth (admin/drsoheili), Let's Encrypt cert (webroot /www/acme, auto-renew scheduled).
- The previous catch-all behavior for this domain is now shadowed by the dedicated vhost /www/server/panel/vhost/nginx/kong.ai.ismc.ir.conf.
- Release copy at ~/kong-gateway-release == github main (37d0d92).
- NOTE (52 BaoTa quirk): the panel re-locks /www/server/panel/vhost to mode 600 between sudo sessions. Any root script touching the vhost tree must run `chmod 755 /www/server/panel/vhost /www/server/panel/vhost/nginx` as its first step, in a single atomic sudo session.
- SSH to 52: key auth on port 22 (2222 is GitLab's internal ssh, not host ssh).

---

## 9. SECURITY INCIDENT — SUDO PASSWORD ROTATION (2026-10-17)

A sudo password for `saber` (52+53) was exposed in chat reports and agent working files.
Treated as compromised and fully rotated. **The old and new secrets must not be written
into any repo, report, or this file.**

### What was done
1. **Rotation (52 and 53):** new random 20-char password set on both hosts via
   `usermod -p "$(openssl passwd -6 …)"`. Verified against `/etc/shadow` with
   python `crypt`: old secret matches = NO, new secret matches = YES (both hosts).
2. **Secret storage:** new secret lives at `/root/.sudo-pwd-saber` (600, root) on each
   host, mirrored to `/home/saber/.sudo-pwd` (600, saber) on each host.
3. **Agent access pattern (no secret in transit):** SSH key auth as `saber` (port 22 on
   52, default port on 53), then on-server `cat ~/.sudo-pwd | sudo -S <cmd>`.
   The helper scripts `ssh52-sudo.py` / `ssh53-sudo.py` implement exactly this and
   contain **no** secret.
4. **Scrubbed:**
   - 52 `/tmp` copies shredded (`shred -u`); syslog/tar "hits" confirmed to be
     coincidental 6-digit substrings (timestamps/hashes), full-string count 0.
   - 53 `/tmp` copies (47 files) shredded; repo + home = 0.
   - Local Windows workspace: 6 one-shot scripts containing the secret deleted;
     remaining helpers contain no secret. `release/`, `kong-gateway/` clean.
   - GitHub repo (saber13812002/kong-api-gateway-oss): full-history pickaxe
     (`git log --all -S` and `-G`) = 0 hits, working tree = 0.
   - 52 GitLab storage: grep over the gitlab repository dir = 0.

### Standing rules
- Never print a secret in agent output or commit it to any repo.
- If a secret must cross a channel, it goes via an on-server file read
  (`cat ~/.sudo-pwd | sudo -S …`), never as a literal in a command or file.

---

## 11. SUDOERS MIGRATION + ADMIN-PROXY AUTH CHECK (2026-10-18)

Follow-up to §9/§10: removed the standing risk of a sudo password file and ran an
independent check of the public admin-proxy auth.

### 11.1 Scoped sudoers (replaces password-driven sudo for scoped work)
- **52** `/etc/sudoers.d/saber-ops` (0440, root):
  `saber ALL=(root) NOPASSWD: /usr/sbin/nginx, /usr/bin/nginx, /www/server/nginx/sbin/nginx, /usr/bin/systemctl, /usr/bin/ss, /usr/bin/journalctl, /usr/bin/chmod`
  - All scoped commands verified passwordless (`sudo -n`); negative control
    (unscoped `ls /`) correctly DENIED; `tee`/`chown`/`apt-get` deliberately NOT
    included (first cut was too broad and was tightened).
  - **`/home/saber/.sudo-pwd` on 52 was securely deleted (`shred -u`)** after all
    scoped checks passed. There is no sudo-password fallback on 52.
  - Helper `ssh52-sudo.py` now runs `sudo -n <cmd>` (single binary per rule;
    compound commands are denied by design).
- **53** `/etc/sudoers.d/saber-ops` (0440, root):
  `saber ALL=(root) NOPASSWD: /usr/bin/gitlab-runner verify|status|registry list, /usr/bin/systemctl restart|status|is-active gitlab-runner`
  (kong-gw-oss is docker-managed; saber is in the `docker` group, so no sudo is
  needed there). Negative controls (unscoped `ls`, `gitlab-runner register`)
  correctly DENIED.
  - **`/home/saber/.sudo-pwd` on 53 is KEPT** — 53's `/etc/sudoers` contains a
    broad `saber ALL=(ALL : ALL) ALL` line that cannot be removed without root.
    The password file remains the documented fallback for out-of-scope commands;
    `ssh53-sudo.py` tries `sudo -n` first and only falls back to the file on denial.
- Removing 53's broad `(ALL : ALL) ALL` rule needs a one-time root session
  (console or a temporary NOPASSWD rule) — left as a known follow-up.

### 11.2 Admin-proxy independent auth check (52) — DEFINITIVE
Method: throwaway test vhosts (own cert, known credentials, no prod vhost
touched), tested with `return 200` markers and then proxying to Kong:18001.
- **nginx `auth_basic` works perfectly on this host:** with a known-cred test
  htpasswd on a 443 vhost (unique SNI) → no-auth = **401 + correct realm**,
  wrong-cred = 401, correct-cred = 200 (Kong status returned through).
- `/etc/nginx-htpasswd-kong` is **byte-identical (md5) to its pre-check backup**
  `*.bak-20261017` (3c6b4a23…); file integrity confirmed.
- Production proxy verified after all cleanup: no-auth → **401**
  (`WWW-Authenticate: Basic realm="Kong Admin"`), Kong 18001 serving normally.
- **CONFIRMED CREDENTIAL MISMATCH (unresolved, needs owner input):**
  `admin/drsoheili` is rejected (401) on 52's public proxy AND 53's LAN proxy
  (18002), and `drsoheili` matches neither stored apr1 hash. The file contains
  `admin:<unknown-hash>` and `drsoheili:<hash that does not match "drsoheili">`
  (the user line is named `drsoheili`, not `admin`). So **no currently
  documented password opens the public admin proxy.** The owner believes
  `admin/drsoheili` works — the working secret must be recovered (on-server:
  53's `kong-admin-auth` container env/config, or 52's original setup notes)
  and `/etc/nginx-htpasswd-kong` reconciled. **Treat `admin/drsoheili` as
  UNVERIFIED until then.**
- Kong's own admin API (18001) has NO auth of its own (200 to everything on
  loopback) — the ONLY auth gate is the nginx `auth_basic` on 443. Keep that
  vhost intact at all times.
