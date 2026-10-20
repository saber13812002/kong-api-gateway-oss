#!/usr/bin/env python3
"""Kong OSS Management UI — stdlib only (no third-party deps).

Security model
--------------
* The browser NEVER talks to the Kong Admin API directly; it only talks to
  this service, which proxies to Kong (env KONG_ADMIN).
* Login sets a session cookie (HttpOnly, SameSite=Strict). Mutating
  requests must send the per-session CSRF token in `X-CSRF-Token`.
* RBAC roles (per user, from the users file):
    viewer   — GET endpoints only
    operator — + create/update (POST/PUT)
    admin    — + delete (DELETE) and /api/audit
* Every request is written to a JSONL audit log (user, role, ip, method,
  path, result, duration). No passwords or secrets are ever logged.
* Before any PUT/DELETE the current object is saved to the backup dir
  (JSON, mode 600) — a rollback aid.
* Responses carry a strict CSP (nonce-based), X-Frame-Options: DENY,
  X-Content-Type-Options: nosniff.

Env
---
PORT                  listen port (default 8091)
BASE                  URL prefix when served under a reverse-proxy path (e.g. /admin)
KONG_ADMIN            Kong Admin base URL (default http://kong:8001)
MANAGE_USERS_FILE     path to users file:  user:role:password  (600)
MANAGE_USERS          inline users (same format, \n separated) — fallback
MANAGE_AUDIT_LOG      audit JSONL path (default /var/log/manage/audit.jsonl)
MANAGE_BACKUP_DIR     pre-change backup dir (default /var/backups/manage)
SESSION_TTL           seconds (default 3600)
"""

import json
import os
import secrets
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8091"))
BASE = os.environ.get("BASE", "").rstrip("/")  # e.g. "/admin" when behind a path-based reverse proxy
KONG = os.environ.get("KONG_ADMIN", "http://kong:8001").rstrip("/")
AUDIT = os.environ.get("MANAGE_AUDIT_LOG", "/var/log/manage/audit.jsonl")
BKDIR = os.environ.get("MANAGE_BACKUP_DIR", "/var/backups/manage")
SESSION_TTL = int(os.environ.get("SESSION_TTL", "3600"))

TYPES = ("services", "routes", "consumers", "plugins", "upstreams")
ROLE_RANK = {"viewer": 0, "operator": 1, "admin": 2}

LOCK = threading.Lock()
SESSIONS = {}          # sid -> dict(user, role, csrf, created, last)
LOGIN_FAILS = {}       # ip -> [count, lockout_until]


# ---------------------------------------------------------------- users ----

def _users_env():
    return os.environ.get("MANAGE_USERS_FILE") or os.environ.get("MANAGE_USERS", "")


def load_users():
    """Return {user: (role, password)}. File-backed with mtime reload."""
    spec = _users_env()
    cache = getattr(load_users, "cache", None)
    try:
        if os.path.isabs(spec):
            st = os.stat(spec)
            key = (st.st_mtime, st.st_size)
            if cache is not None and getattr(load_users, "key", None) == key:
                return cache
            with open(spec, "r", encoding="utf-8") as f:
                lines = f.read().splitlines()
            load_users.key = key
        else:
            lines = spec.splitlines()
        users = {}
        for line in lines:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(":")
            if len(parts) != 3:
                continue
            user, role, pw = (p.strip() for p in parts)
            if role not in ROLE_RANK or not user or not pw:
                continue
            users[user] = (role, pw)
        load_users.cache = users
        return users
    except Exception as e:  # never crash the API on a bad users file
        sys.stderr.write("users file error: %r\n" % (e,))
        return cache or {}


# --------------------------------------------------------------- kong ------

def kong_call(method, path, body=None):
    url = KONG + path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read()
            try:
                return r.status, (json.loads(raw) if raw else None)
            except ValueError:
                return r.status, raw.decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, (json.loads(raw) if raw else None)
        except ValueError:
            return e.code, raw.decode("utf-8", "replace")[:500]
    except Exception as e:
        return 502, {"error": "kong unreachable", "detail": str(e)}


# --------------------------------------------------------------- audit -----

def audit_line(user, role, ip, method, path, code, ms, note=""):
    rec = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "user": user or "-",
        "role": role or "-",
        "ip": ip,
        "method": method,
        "path": path,
        "result": code,
        "ms": ms,
        "note": note,
    }
    try:
        with LOCK:
            os.makedirs(os.path.dirname(AUDIT), exist_ok=True)
            with open(AUDIT, "a", encoding="utf-8") as f:
                f.write(json.dumps(rec) + "\n")
    except Exception:
        pass  # audit must never break the request path


def backup_entity(t, ident, obj):
    try:
        os.makedirs(BKDIR, exist_ok=True)
        safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in str(ident))
        p = os.path.join(BKDIR, "%d-%s-%s.json" % (int(time.time()), t, safe))
        with open(p, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=2, sort_keys=True)
        os.chmod(p, 0o600)
        return os.path.basename(p)
    except Exception:
        return ""


# -------------------------------------------------------------- sessions ---

def sess_touch(sid):
    with LOCK:
        s = SESSIONS.get(sid)
        if not s:
            return None
        now = time.time()
        if now - s["last"] > SESSION_TTL or now - s["created"] > SESSION_TTL * 3:
            del SESSIONS[sid]
            return None
        s["last"] = now
        return s


def sess_delete(sid):
    with LOCK:
        SESSIONS.pop(sid, None)


def _sid_from(headers):
    c = headers.get("Cookie", "")
    for part in c.split(";"):
        k, _, v = part.strip().partition("=")
        if k == "sid":
            return v
    return None


def sess_create(user, role):
    sid = secrets.token_hex(32)
    with LOCK:
        # prune expired
        now = time.time()
        for k in [k for k, v in SESSIONS.items()
                  if now - v["last"] > SESSION_TTL or now - v["created"] > SESSION_TTL * 3]:
            del SESSIONS[k]
        SESSIONS[sid] = {
            "user": user, "role": role,
            "csrf": secrets.token_hex(16),
            "created": now, "last": now,
        }
    return sid


def login_ok(ip, username, password):
    now = time.time()
    with LOCK:
        cnt, until = LOGIN_FAILS.get(ip, (0, 0))
        if now < until:
            return None
    users = load_users()
    got = users.get(username)
    if got and secrets.compare_digest(got[1], password or ""):
        with LOCK:
            LOGIN_FAILS.pop(ip, None)
        return got[0]
    with LOCK:
        cnt, _ = LOGIN_FAILS.get(ip, (0, 0))
        cnt += 1
        LOGIN_FAILS[ip] = (cnt, now + 60 if cnt >= 5 else 0)
    return None


# ------------------------------------------------------------- validation --

REQUIRED = {
    "services": ("name", "url"),
    "routes": ("name",),
    "consumers": ("username",),
    "plugins": ("name",),
    "upstreams": ("name", "host"),
}


def validate(t, body):
    if not isinstance(body, dict):
        return "body must be a JSON object"
    for k in REQUIRED[t]:
        v = body.get(k)
        if not isinstance(v, str) or not v.strip():
            return "missing required field: %s" % k
    if t == "routes" and not (body.get("paths") or body.get("hosts") or body.get("service")):
        return "route needs paths, hosts, or a service reference"
    if t == "plugins" and "config" not in body:
        body["config"] = {}
    return None


# -------------------------------------------------------------------- ui ---

def csp(nonce):
    return ("default-src 'none'; base-uri 'none'; object-src 'none'; "
            "script-src 'nonce-%s'; style-src 'nonce-%s'; img-src 'data:'; "
            "form-action 'self'; frame-ancestors 'none'" % (nonce, nonce))


def page_login():
    return """<!doctype html>
<html><head><meta charset="utf-8"><title>Kong Admin — Login</title>
<style nonce="__N__">body{font-family:system-ui,sans-serif;background:#10141a;color:#e6e9ee;
display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
form{background:#1a2029;padding:28px 32px;border-radius:10px;box-shadow:0 8px 30px #0008}
input{display:block;width:260px;margin:10px 0;padding:9px;border-radius:6px;border:1px solid #33405a;
background:#0d1117;color:#e6e9ee}button{margin-top:14px;padding:9px 22px;border:0;border-radius:6px;
background:#2f81f7;color:#fff;font-size:15px;cursor:pointer}.err{color:#f85149;font-size:13px}
h1{font-size:17px;margin:0 0 6px}.muted{color:#8b98ad;font-size:12px}</style>
<script nonce="__N__">
(async function(){
  const B="__B__";
  const f=document.getElementById('f'), e=document.getElementById('e');
  f.addEventListener('submit',async ev=>{
    ev.preventDefault();
    const r=await fetch(B+'/login',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({username:f.username.value,password:f.password.value})});
    if(r.ok)location.reload(); else e.textContent='invalid credentials';
  });
})();
</script></head><body>
<form id="f"><h1>Kong OSS — Management UI</h1>
<div class="muted">session auth + CSRF + RBAC; browser never reaches the Admin API</div>
<input name="username" autocomplete="username" required>
<input name="password" type="password" autocomplete="current-password" required>
<button type="submit">Sign in</button>
<div class="err" id="e"></div></form></body></html>""".replace("__N__", "REPLACED_NONCE").replace("__B__", "REPLACED_BASE")


def page_app(role):
    return """<!doctype html>
<html><head><meta charset="utf-8"><title>Kong Admin</title>
<style nonce="__N__">body{font-family:system-ui,sans-serif;background:#10141a;color:#e6e9ee;margin:0}
header{display:flex;align-items:center;gap:14px;padding:10px 18px;background:#161c26;border-bottom:1px solid #2a3446}
header h1{font-size:15px;margin:0}select,textarea,button,input{font-family:inherit}
.badge{font-size:11px;padding:2px 9px;border-radius:10px;background:#2f81f722;color:#79b8ff;border:1px solid #2f81f755}
.tabbar{display:flex;gap:6px;padding:10px 18px;flex-wrap:wrap}
.tab{padding:7px 14px;border-radius:7px;background:#1a2029;cursor:pointer;border:1px solid #2a3446;font-size:13px}
.tab.on{background:#2f81f7;color:#fff;border-color:#2f81f7}
main{display:flex;gap:14px;padding:14px 18px}
#list{flex:1.2;min-width:320px}#detail{flex:1;min-width:320px}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:7px 9px;
border-bottom:1px solid #232c3b}th{color:#8b98ad;font-weight:600}tr:hover td{background:#161c26}
.panel{background:#161c26;border:1px solid #2a3446;border-radius:9px;padding:12px;margin-bottom:12px}
.panel h2{font-size:14px;margin:0 0 10px}
button{padding:7px 14px;border:0;border-radius:6px;background:#2f81f7;color:#fff;cursor:pointer;font-size:13px}
button.warn{background:#f85149}button.ghost{background:#232c3b;color:#cdd6e4}
textarea{width:100%;height:340px;background:#0d1117;color:#d7e0ec;border:1px solid #33405a;
border-radius:7px;padding:10px;font-family:ui-monospace,Consolas,monospace;font-size:12.5px}
.muted{color:#8b98ad;font-size:12px}.row{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}
#status{font-size:12px;color:#8b98ad;margin-left:auto}a{color:#79b8ff}</style>
<script nonce="__N__">
const B="__B__";
const ROLE=__ROLE__;
let TYPE='services', SEL=null;
const $=id=>document.getElementById(id);
function api(path,opt){opt=opt||{};opt.headers=Object.assign({'Content-Type':'application/json'},opt.headers||{});
  if(!['GET','HEAD'].includes(opt.method||'GET'))opt.headers['X-CSRF-Token']=window.CSRF;
  return fetch(B+path,opt);}
async function load(){const r=await api('/api/'+TYPE);const j=await r.json();
  $('status').textContent='http '+r.status;renderList(j.data||[]);}
function renderList(items){const t=$('tbody');t.innerHTML='';
  for(const it of items){const tr=document.createElement('tr');
    const name=(it.name||it.username||'-');
    let extra='';
    if(it.url)extra=' '+it.url; if(it.hosts)extra=' '+(Array.isArray(it.hosts)?it.hosts.join(', '):it.hosts);
    if(it.paths)extra=' '+(Array.isArray(it.paths)?it.paths.join(', '):it.paths);
    if(it.name==='rate-limiting'||it.config)extra=' cfg';
    tr.innerHTML='<td style="cursor:pointer"><b>'+esc(name)+'</b>'+esc(extra)+'</td><td>'+esc((it.id||'').slice(0,8))+'</td>';
    tr.querySelector('td').onclick=()=>openDetail(it);t.appendChild(tr);}
}
function esc(s){var Q=String.fromCharCode(38);return String(s).replace(/[&<>"]/g,function(c){return c==='&'?Q+'amp;':c==='<'?Q+'lt;':c==='>'?Q+'gt;':Q+'quot;';});}
async function openDetail(it){SEL=it;const r=await api('/api/'+TYPE+'/'+encodeURIComponent(it.id));
  const j=await r.json();$('editor').value=JSON.stringify(j,null,2);$('dname').textContent=(it.name||it.username||it.id);}
async function save(create){const body=JSON.parse($('editor').value);
  const path=create?'/api/'+TYPE:'/api/'+TYPE+'/'+encodeURIComponent(SEL.id);
  const method=create?'POST':'PUT';
  const r=await api(path,{method:method,body:JSON.stringify(body)});
  $('status').textContent=(create?'created ':'updated ')+(SEL?(SEL.name||SEL.id):'')+ ' → http '+r.status;
  load();}
async function del(){if(!SEL)return;const nm=SEL.name||SEL.username||SEL.id;
  if(!confirm('DELETE '+nm+' ?\\nA pre-change backup is saved server-side before the call.'))return;
  const r=await api('/api/'+TYPE+'/'+encodeURIComponent(SEL.id),{method:'DELETE'});
  $('status').textContent='deleted '+nm+' → http '+r.status;load();}
async function newTpl(){const tpls={services:{name:'',url:''},routes:{name:'',paths:['/x'],strip_path:true},
  consumers:{username:''},plugins:{name:'key-auth',config:{}},upstreams:{name:'',host:''}};
  SEL=null;$('dname').textContent='new '+TYPE.slice(0,-1);$('editor').value=JSON.stringify(tpls[TYPE]||{},null,2);
  $('btnCreate').style.display='';$('btnSave').style.display='none';}
function setTab(t){TYPE=t;document.querySelectorAll('.tab').forEach(x=>x.classList.toggle('on',x.dataset.t===t));
  $('btnCreate').style.display='';$('btnSave').style.display='none';SEL=null;
  $('dname').textContent='—';$('editor').value='';load();}
window.CSRF="__CSRF__";
load();
</script></head><body>
<header><h1>Kong OSS — Management UI</h1><span class="badge" id="role"></span>
<span class="muted" id="kver"></span><span id="status"></span>
<button class="ghost" onclick="location.href=B+'/logout';fetch(B+'/logout',{method:'POST'}).then(()=>location.href=B)">log out</button></header>
<div class="tabbar" id="tabs"></div>
<main>
<div id="list"><div class="panel"><h2 id="ltitle"></h2>
<table><thead><tr><th>name</th><th>id</th></tr></thead><tbody id="tbody"></tbody></table></div></div>
<div id="detail"><div class="panel"><h2 id="dname">—</h2>
<textarea id="editor" spellcheck="false"></textarea>
<div class="row"><button id="btnSave" style="display:none" onclick="save(false)">Save (PUT)</button>
<button id="btnCreate" class="ghost" onclick="save(true)">Create (POST)</button>
<button class="warn" onclick="del()">Delete</button></div>
<div class="muted" style="margin-top:8px" id="rolehint"></div></div></div>
</main>
<script nonce="__N__">
document.getElementById('role').textContent='role: '+ROLE;
document.getElementById('rolehint').textContent = ROLE==='viewer'
 ? 'viewer role: read-only. Writes are rejected (403).'
 : ROLE==='operator' ? 'operator role: create/update allowed; delete requires admin.'
 : 'admin role: full access.';
const tabs=document.getElementById('tabs');
['services','routes','consumers','plugins','upstreams'].forEach(t=>{const d=document.createElement('div');
 d.className='tab'+(t==='services'?' on':'');d.dataset.t=t;d.textContent=t;
 d.onclick=()=>setTab(t);tabs.appendChild(d);});
document.getElementById('ltitle').textContent='services';
api('/api/kong').then(r=>r.json()).then(j=>{document.getElementById('kver').textContent='kong '+(j.version||'?');}).catch(()=>{});
</script></body></html>""".replace("__N__", "REPLACED_NONCE").replace("__ROLE__", json.dumps(role)).replace("__CSRF__", "REPLACED_CSRF").replace("__B__", "REPLACED_BASE")


# --------------------------------------------------------------- handler ---

class H(BaseHTTPRequestHandler):
    server_version = "KongManage/2.0"
    protocol_version = "HTTP/1.1"

    # ---- plumbing ---------------------------------------------------------
    def _send(self, code, body, ctype="application/json", headers=None):
        if isinstance(body, (dict, list)):
            data = json.dumps(body, indent=2, sort_keys=True).encode("utf-8")
        elif isinstance(body, str):
            data = body.encode("utf-8")
        else:
            data = (body or b"")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", csp(self._nonce))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _nonce(self):
        return getattr(self, "_n", None) or "x"

    def _sess(self):
        c = self.headers.get("Cookie", "")
        for part in c.split(";"):
            k, _, v = part.strip().partition("=")
            if k == "sid":
                return sess_touch(v)
        return None

    def _audit(self, s, code, ms, note=""):
        audit_line(s["user"] if s else None, s["role"] if s else None,
                   self.client_address[0], self.command, self.path, code, ms, note)

    def _drain(self):
        """Read and return the request body (keeps keep-alive connections clean)."""
        try:
            n = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError:
            n = 0
        if n <= 0:
            return b""
        if n > 1_000_000:
            self.rfile.read(min(n, 1_000_001))
            return b"__TOO_LARGE__"
        return self.rfile.read(n)

    def _body(self, raw=None):
        if raw is None:
            raw = self._drain()
        if raw == b"__TOO_LARGE__":
            return "too large"
        if not raw:
            return None
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError:
            return "invalid json"

    def _need_csrf(self, s):
        return self.headers.get("X-CSRF-Token") == s["csrf"]

    # ---- routes -----------------------------------------------------------
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        t0 = time.time()
        u = urllib.parse.urlparse(self.path)
        path = u.path
        nonce = secrets.token_urlsafe(16)
        self._n = nonce

        s = self._sess()

        if path == "/":
            if not s:
                self._audit(s, 200, int((time.time() - t0) * 1000))
                return self._send(200, page_login().replace("REPLACED_NONCE", nonce).replace("REPLACED_BASE", BASE),
                                   "text/html; charset=utf-8")
            self._audit(s, 200, int((time.time() - t0) * 1000))
            return self._send(200, page_app(s["role"]).replace("REPLACED_NONCE", nonce)
                                          .replace("REPLACED_CSRF", s["csrf"]).replace("REPLACED_BASE", BASE),
                                   "text/html; charset=utf-8")

        if path == "/logout":
            sid = _sid_from(self.headers)
            if sid:
                sess_delete(sid)
            return self._send(204, b"", headers={"Set-Cookie": "sid=; Path=/; Max-Age=0"})

        if not path.startswith("/api/"):
            self._audit(s, 404, int((time.time() - t0) * 1000))
            return self._send(404, {"error": "not found"})
        return self._api(t0, path, s)

    # ---- API dispatch (GET/POST/PUT/DELETE) ----------------------------
    def _api(self, t0, path, s):
        if s is None:
            self._audit(None, 401, int((time.time() - t0) * 1000))
            return self._send(401, {"error": "unauthorized", "hint": "POST /login"})

        parts = [p for p in path.split("/") if p]  # ['api', type, id?]
        kind = parts[1] if len(parts) > 1 else ""

        if kind == "health":
            code, info = kong_call("GET", "/")
            self._audit(s, 200, int((time.time() - t0) * 1000))
            return self._send(200, {"ok": code == 200, "kong_version": (info or {}).get("version") if isinstance(info, dict) else None,
                                    "role": s["role"], "user": s["user"]})

        if kind == "kong":
            code, info = kong_call("GET", "/")
            self._audit(s, code, int((time.time() - t0) * 1000))
            return self._send(code, info if isinstance(info, (dict, list)) else {"raw": info})

        if kind == "audit":
            if s["role"] != "admin":
                self._audit(s, 403, int((time.time() - t0) * 1000))
                return self._send(403, {"error": "admin role required"})
            n = 50
            try:
                n = min(int(urllib.parse.parse_qs(urllib.parse.urlparse(path).query).get("lines", ["50"])[0]), 500)
            except ValueError:
                pass
            lines = []
            try:
                with open(AUDIT, "r", encoding="utf-8") as f:
                    for ln in f.readlines()[-n:]:
                        try:
                            lines.append(json.loads(ln))
                        except ValueError:
                            pass
            except Exception:
                pass
            self._audit(s, 200, int((time.time() - t0) * 1000))
            return self._send(200, {"count": len(lines), "data": lines})

        if kind not in TYPES:
            self._audit(s, 404, int((time.time() - t0) * 1000))
            return self._send(404, {"error": "unknown collection"})

        ident = urllib.parse.unquote(parts[2]) if len(parts) > 2 else None

        # ---- reads: all roles -------------------------------------------
        if self.command == "GET":
            if ident is None:
                code, info = kong_call("GET", "/" + kind)
            else:
                code, info = kong_call("GET", "/%s/%s" % (kind, ident))
            self._audit(s, code, int((time.time() - t0) * 1000))
            return self._send(code, info if isinstance(info, (dict, list)) else {"raw": info})

        # ---- writes: CSRF + role ------------------------------------------
        raw = self._drain()  # keep keep-alive clean even on early reject
        if not self._need_csrf(s):
            self._audit(s, 403, int((time.time() - t0) * 1000), "csrf")
            return self._send(403, {"error": "csrf token missing or invalid"})

        if self.command in ("POST", "PUT"):
            if ROLE_RANK[s["role"]] < 1:
                self._audit(s, 403, int((time.time() - t0) * 1000), "rbac")
                return self._send(403, {"error": "viewer role cannot write"})
        else:  # DELETE
            if s["role"] != "admin":
                self._audit(s, 403, int((time.time() - t0) * 1000), "rbac")
                return self._send(403, {"error": "admin role required for delete"})

        if self.command == "DELETE" and ident is None:
            self._audit(s, 400, int((time.time() - t0) * 1000))
            return self._send(400, {"error": "ident required"})

        # pre-change backup for PUT/DELETE
        if self.command in ("PUT", "DELETE") and ident:
            code, cur = kong_call("GET", "/%s/%s" % (kind, ident))
            if code == 200 and isinstance(cur, dict):
                bname = backup_entity(kind, ident, cur)
                if bname:
                    self._bk = bname

        body = self._body(raw) if self.command in ("POST", "PUT") else None
        if isinstance(body, str):
            self._audit(s, 400, int((time.time() - t0) * 1000), body)
            return self._send(400, {"error": body})

        if self.command in ("POST", "PUT"):
            err = validate(kind, body)
            if err:
                self._audit(s, 400, int((time.time() - t0) * 1000), err)
                return self._send(400, {"error": err})

        if self.command == "POST":
            code, info = kong_call("POST", "/" + kind, body)
        elif self.command == "PUT":
            code, info = kong_call("PUT", "/%s/%s" % (kind, ident), body)
        else:
            code, info = kong_call("DELETE", "/%s/%s" % (kind, ident))

        note = getattr(self, "_bk", "")
        self._audit(s, code, int((time.time() - t0) * 1000), note)
        return self._send(code, info if isinstance(info, (dict, list)) else {"raw": info} if info is not None else b"")

    def do_POST(self):
        if self.path == "/login":
            t0 = time.time()
            body = self._body()
            if not isinstance(body, dict):
                self._audit(None, 400, int((time.time() - t0) * 1000))
                return self._send(400, {"error": "invalid json"})
            role = login_ok(self.client_address[0], body.get("username", ""), body.get("password", ""))
            ms = int((time.time() - t0) * 1000)
            if role is None:
                self._audit(None, 401, ms, "login-fail")
                return self._send(401, {"error": "invalid credentials"})
            sid = sess_create(body["username"], role)
            self._audit(SESSIONS[sid], 200, ms, "login")
            return self._send(200, {"ok": True, "user": body["username"], "role": role,
                                    "csrf": SESSIONS[sid]["csrf"]},
                             headers={"Set-Cookie": "sid=%s; Path=/; HttpOnly; SameSite=Strict" % sid})
        if self.path == "/logout":
            self._drain()
            sid = _sid_from(self.headers)
            if sid:
                sess_delete(sid)
            self._send(204, b"", headers={"Set-Cookie": "sid=; Path=/; Max-Age=0"})
            return
        self.do_POST_api()

    def do_PUT(self):
        self.do_POST_api()

    def do_DELETE(self):
        self.do_POST_api()

    def do_POST_api(self):
        self.do_GET()

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main():
    os.makedirs(BKDIR, exist_ok=True)
    os.makedirs(os.path.dirname(AUDIT) or ".", exist_ok=True)
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), H)
    sys.stderr.write("manage listening on %d, kong=%s users=%s\n"
                     % (PORT, KONG, sorted(load_users().keys()) or "NONE"))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
