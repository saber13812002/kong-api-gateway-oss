#!/usr/bin/env python3
"""Focused check: manage.py served under a reverse-proxy path prefix (BASE=/admin).

The server logic is prefix-agnostic (nginx strips /admin/ via proxy_pass),
so this test only verifies the rendered HTML/JS carries the right prefix:
  - login page:  const B="/admin"  and  fetch(B+'/login')
  - app page:    const B="/admin"  and  window.CSRF="..." present
  - /admin/login POST reaches the server (cookie issued)
  - /api/... routing works with the session cookie
Kong admin is pointed at a dead port: server-rendered pages never call Kong,
and /api/services must return 502 (kong unreachable) NOT 404 (routing ok).
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

PORT = 18503
BASE_URL = f"http://127.0.0.1:{PORT}"
HERE = os.path.dirname(os.path.abspath(__file__))
MANAGE = os.path.join(HERE, "..", "panel", "manage.py")

PASS = 0
FAIL = 0


def check(name, cond, extra=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS  {name}  [{extra}]")
    else:
        FAIL += 1
        print(f"FAIL  {name}  [{extra}]")


def req(path, data=None, headers=None, cookie=None, method=None):
    h = dict(headers or {})
    if cookie:
        h["Cookie"] = cookie
    body = data.encode() if isinstance(data, str) else data
    r = urllib.request.Request(BASE_URL + path, data=body, headers=h,
                               method=method or ("POST" if body is not None else "GET"))
    try:
        with urllib.request.urlopen(r, timeout=5) as resp:
            return resp.status, resp.read().decode(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(), dict(e.headers)


def main():
    env = dict(os.environ)
    env.update({
        "PORT": str(PORT),
        "BASE": "/admin",
        "KONG_ADMIN": "http://127.0.0.1:1",  # dead on purpose
        # ephemeral test-fixture credentials (injected only into this
        # subprocess's env; never used outside this test)
        "MANAGE_USERS": "baseuser:admin:basewpw123\nviewer1:viewer:vviewpw1",
        "MANAGE_AUDIT_LOG": "/tmp/mtest-base-audit.jsonl",
        "MANAGE_BACKUP_DIR": "/tmp/mtest-base-bk",
    })
    for p in (env["MANAGE_AUDIT_LOG"],):
        if os.path.exists(p):
            os.remove(p)

    proc = subprocess.Popen([sys.executable, MANAGE], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(50):
            if proc.poll() is not None:
                print("FAIL  manage.py exited early")
                return 1
            try:
                urllib.request.urlopen(BASE_URL + "/", timeout=1)
                break
            except Exception:
                time.sleep(0.1)
        else:
            print("FAIL  manage.py did not start")
            return 1

        # 1) login page carries the prefix
        c, b, _ = req("/")
        check("login page 200", c == 200, c)
        check("login page: const B=/admin", 'const B="/admin"' in b, "")
        check("login page: fetch(B+'/login')", "fetch(B+'/login'" in b, "")

        # 2) login via the (un-prefixed) server route — nginx will strip /admin/
        c, b, h = req("/login", data=json.dumps({"username": "baseuser", "password": "basewpw123"}),
                      headers={"Content-Type": "application/json"})
        check("login 200", c == 200, c)
        sc = h.get("Set-Cookie", "")
        sid = ""
        for part in sc.split(";"):
            if part.strip().startswith("sid="):
                sid = part.strip()[4:]
        check("sid cookie issued (Path=/)", "Path=/" in sc and sid, "sid-set" if sid else sc)
        csrf = json.loads(b).get("csrf", "") if b else ""
        check("csrf in login response", len(csrf) >= 16, f"len={len(csrf)}")

        # 3) app page carries the prefix
        c, b, _ = req("/", cookie=f"sid={sid}")
        check("app page 200", c == 200, c)
        check("app page: const B=/admin", 'const B="/admin"' in b, "")
        check("app page: fetch(B+path)", "return fetch(B+path,opt)" in b, "")
        check("app page: CSRF injected", f'window.CSRF="{csrf}";' in b, "")
        check("app page: logout uses B", "location.href=B+'/logout'" in b, "")

        # 4) API routing with session cookie (Kong dead -> 502, NOT 404)
        c, _, _ = req("/api/services", cookie=f"sid={sid}")
        check("/api/services routed (502 = kong down, not 404)", c == 502, c)
        c, _, _ = req("/api/nope-x", cookie=f"sid={sid}")
        check("unknown api path -> 404", c == 404, c)

        # 5) viewer role page still renders with prefix
        c, b2, h2 = req("/login", data=json.dumps({"username": "viewer1", "password": "vviewpw1"}),
                        headers={"Content-Type": "application/json"})
        sid2 = ""
        for part in h2.get("Set-Cookie", "").split(";"):
            if part.strip().startswith("sid="):
                sid2 = part.strip()[4:]
        c, b3, _ = req("/", cookie=f"sid={sid2}")
        check("viewer app page 200 + prefix", c == 200 and 'const B="/admin"' in b3, c)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()

    print(f"\n{PASS} passed, {FAIL} failed")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
