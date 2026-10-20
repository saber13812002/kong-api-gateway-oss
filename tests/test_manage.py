#!/usr/bin/env python3
"""Functional test for panel/manage.py (the Kong Management UI backend).

Runs entirely on localhost:
  * a stub Kong Admin API (in-memory) on 127.0.0.1:18501
  * manage.py (subprocess) on 127.0.0.1:18502

Covers: login, RBAC (viewer/operator/admin), CSRF, validation,
pre-change backups, audit log, and Kong proxying.

Exit code 0 = all pass. No third-party deps.
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANAGE = os.path.join(HERE, "panel", "manage.py")
KONG_PORT = 18501
MGMT_PORT = 18502
TMP = tempfile.mkdtemp(prefix="manage-test-")
AUDIT = os.path.join(TMP, "audit.jsonl")
BKDIR = os.path.join(TMP, "backups")
USERS = os.path.join(TMP, "users.txt")

PASS = []
FAIL = []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("PASS  " if cond else "FAIL  ") + name + (("  [%s]" % extra) if extra else ""))


# ---------------------------------------------------------------- stub -----

class StubKong(BaseHTTPRequestHandler):
    store = {
        "services": [{"id": "svc-1", "name": "test-echo-service", "url": "http://echo:9000"}],
        "routes": [{"id": "rt-1", "name": "test-echo", "paths": ["/test-echo"]}],
        "consumers": [{"id": "con-1", "username": "demo"}],
        "plugins": [{"id": "pl-1", "name": "key-auth", "config": {}}],
        "upstreams": [],
    }
    counter = [100]

    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        p = self.path.rstrip("/").split("/")
        if len(p) == 1:
            return self._json(200, {"version": "3.9.4-stub"})
        if p[1] in StubKong.store:
            if len(p) == 2:
                return self._json(200, {"data": StubKong.store[p[1]]})
            for it in StubKong.store[p[1]]:
                if it["id"] == p[2]:
                    return self._json(200, it)
            return self._json(404, {"message": "Not found"})
        return self._json(404, {"message": "nope"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        coll = self.path.rstrip("/").split("/")[1]
        if coll not in StubKong.store:
            return self._json(404, {"message": "nope"})
        if "name" in body:
            for it in StubKong.store[coll]:
                if it.get("name") == body["name"]:
                    return self._json(409, {"message": "already exists"})
        StubKong.counter[0] += 1
        body["id"] = "new-%d" % StubKong.counter[0]
        StubKong.store[coll].append(body)
        return self._json(201, body)

    def do_PUT(self):
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        p = self.path.rstrip("/").split("/")
        coll, ident = p[1], p[2]
        for it in StubKong.store.get(coll, []):
            if it["id"] == ident:
                it.update(body)
                return self._json(200, it)
        return self._json(404, {"message": "not found"})

    def do_DELETE(self):
        p = self.path.rstrip("/").split("/")
        coll, ident = p[1], p[2]
        for i, it in enumerate(StubKong.store.get(coll, [])):
            if it["id"] == ident:
                StubKong.store[coll].pop(i)
                return self._json(204, {})
        return self._json(404, {"message": "not found"})

    def log_message(self, *a):
        pass


def req(method, port, path, body=None, cookie=None, csrf=None, headers=None):
    url = "http://127.0.0.1:%d%s" % (port, path)
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Content-Type", "application/json")
    if cookie:
        r.add_header("Cookie", cookie)
    if csrf:
        r.add_header("X-CSRF-Token", csrf)
    for k, v in (headers or {}).items():
        r.add_header(k, v)
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            raw = resp.read()
            try:
                return resp.status, json.loads(raw) if raw else {}, dict(resp.headers)
            except ValueError:
                return resp.status, raw.decode("utf-8", "replace"), dict(resp.headers)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw) if raw else {}, dict(e.headers)
        except ValueError:
            return e.code, raw.decode("utf-8", "replace"), dict(e.headers)


def login(user, pw):
    st, j, h = req("POST", MGMT_PORT, "/login", {"username": user, "password": pw})
    ck = h.get("Set-Cookie", "")
    sid = ck.split(";")[0] if ck else ""
    return st, j, sid


def main():
    with open(USERS, "w") as f:
        f.write("alice:admin:%s\nbob:operator:%s\ncarol:viewer:%s\n" % ("pwA", "pwB", "pwC"))

    stub = ThreadingHTTPServer(("127.0.0.1", KONG_PORT), StubKong)
    threading.Thread(target=stub.serve_forever, daemon=True).start()

    env = dict(os.environ)
    env.update({
        "PORT": str(MGMT_PORT),
        "KONG_ADMIN": "http://127.0.0.1:%d" % KONG_PORT,
        "MANAGE_USERS_FILE": USERS,
        "MANAGE_AUDIT_LOG": AUDIT,
        "MANAGE_BACKUP_DIR": BKDIR,
    })
    proc = subprocess.Popen([sys.executable, MANAGE], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        time.sleep(1.2)

        # ---- unauthenticated ------------------------------------------------
        st, j, _ = req("GET", MGMT_PORT, "/")
        check("GET / no session -> login page", st == 200 and "Sign in" in j, str(st))
        st, j, _ = req("GET", MGMT_PORT, "/api/services")
        check("GET /api/services no session -> 401", st == 401, str(st))

        # ---- login ----------------------------------------------------------
        st, j, _ = login("alice", "wrong")
        check("login wrong password -> 401", st == 401, str(st))
        st, j, alice = login("alice", "pwA")
        check("login admin ok", st == 200 and j.get("role") == "admin", str(st))
        alice_csrf = j.get("csrf", "")
        st, j, bob = login("bob", "pwB")
        check("login operator ok", st == 200 and j.get("role") == "operator", str(st))
        bob_csrf = j.get("csrf", "")
        st, j, carol = login("carol", "pwC")
        check("login viewer ok", st == 200 and j.get("role") == "viewer", str(st))
        carol_csrf = j.get("csrf", "")

        # ---- reads ----------------------------------------------------------
        st, j, _ = req("GET", MGMT_PORT, "/api/services", cookie=carol)
        check("viewer GET services -> 200 + data", st == 200 and any(s["name"] == "test-echo-service" for s in j.get("data", [])), str(st))
        st, j, _ = req("GET", MGMT_PORT, "/api/services/svc-1", cookie=carol)
        check("viewer GET service by id -> 200", st == 200 and j.get("url") == "http://echo:9000", str(st))
        st, j, _ = req("GET", MGMT_PORT, "/api/kong", cookie=alice)
        check("GET /api/kong proxy -> version", st == 200 and j.get("version") == "3.9.4-stub", str(st))

        # ---- CSRF enforcement ------------------------------------------------
        st, j, _ = req("POST", MGMT_PORT, "/api/services", {"name": "x", "url": "http://x"}, cookie=alice)
        check("POST without CSRF -> 403", st == 403, str(st))
        st, j, _ = req("POST", MGMT_PORT, "/api/services", {"name": "x", "url": "http://x"}, cookie=alice, csrf="badtoken")
        check("POST with wrong CSRF -> 403", st == 403, str(st))

        # ---- RBAC -------------------------------------------------------------
        st, j, _ = req("POST", MGMT_PORT, "/api/services", {"name": "x", "url": "http://x"}, cookie=carol, csrf=carol_csrf)
        check("viewer POST -> 403 (rbac)", st == 403, str(st))
        st, j, _ = req("DELETE", MGMT_PORT, "/api/consumers/con-1", cookie=bob, csrf=bob_csrf)
        check("operator DELETE -> 403 (rbac)", st == 403, str(st))
        st, j, _ = req("GET", MGMT_PORT, "/api/audit", cookie=bob)
        check("operator GET /api/audit -> 403", st == 403, str(st))

        # ---- validation --------------------------------------------------------
        st, j, _ = req("POST", MGMT_PORT, "/api/services", {"name": "no-url"}, cookie=alice, csrf=alice_csrf)
        check("POST service missing url -> 400", st == 400, str(st))

        # ---- write ops (admin) ---------------------------------------------------
        st, j, _ = req("POST", MGMT_PORT, "/api/services",
                      {"name": "mtest-svc", "url": "http://127.0.0.1:9"},
                      cookie=alice, csrf=alice_csrf)
        check("admin POST service -> 201", st == 201 and j.get("name") == "mtest-svc", str(st))
        new_id = j.get("id", "")

        st, j, _ = req("PUT", MGMT_PORT, "/api/services/" + new_id,
                      {"name": "mtest-svc", "url": "http://127.0.0.1:10"},
                      cookie=bob, csrf=bob_csrf)
        check("operator PUT service -> 200", st == 200 and j.get("url") == "http://127.0.0.1:10", str(st))

        time.sleep(0.2)
        bks = [f for f in os.listdir(BKDIR) if f.endswith(".json")] if os.path.isdir(BKDIR) else []
        check("pre-change backup written", len(bks) >= 1, ",".join(bks))
        if bks:
            with open(os.path.join(BKDIR, sorted(bks)[-1])) as f:
                bj = json.load(f)
            check("backup holds PRE-change url", bj.get("url") == "http://127.0.0.1:9", str(bj.get("url")))

        st, j, _ = req("DELETE", MGMT_PORT, "/api/services/" + new_id, cookie=alice, csrf=alice_csrf)
        check("admin DELETE service -> 204", st == 204, str(st))
        st, j, _ = req("GET", MGMT_PORT, "/api/services/" + new_id, cookie=alice)
        check("deleted service -> 404", st == 404, str(st))

        # ---- audit log ------------------------------------------------------------
        time.sleep(0.2)
        with open(AUDIT) as f:
            lines = [json.loads(l) for l in f if l.strip()]
        ops = {(l["method"], l["path"]) for l in lines}
        check("audit log has login entry", any(l.get("note") == "login" for l in lines))
        check("audit log has write entries", ("PUT", "/api/services/%s" % new_id) in ops)
        check("audit log has rbac/csf rejections", any(l.get("note") in ("rbac", "csrf") for l in lines))
        check("audit log has no password field", all("password" not in l for l in lines))

        # ---- session invalidation ----------------------------------------------------
        st, j, _ = req("GET", MGMT_PORT, "/logout", cookie=carol)
        st, j, _ = req("GET", MGMT_PORT, "/api/services", cookie=carol)
        check("session cleared after logout -> 401", st == 401, str(st))

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        stub.shutdown()

    print("\n%d passed, %d failed" % (len(PASS), len(FAIL)))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
