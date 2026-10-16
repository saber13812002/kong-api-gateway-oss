#!/usr/bin/env python3
"""Deterministic echo backend for Kong OSS functional testing.

Endpoints:
  GET  /health        -> {"status":"ok","backend":<ECHO_BACKEND_NAME>}
  GET  *              -> JSON echo of method, path, query, headers
  POST *              -> JSON echo incl. parsed body + raw byte count
  GET/POST /fixed-ok  -> exact body {"status":"ok","data":{"id":123}}
  GET      /empty     -> 200, empty body (Content-Length: 0)
  GET      /not-json  -> 200, text/plain, non-JSON body
  GET/POST /echo-error-> 500, JSON error body
  POST     /combined-echo -> validates the *transformed* request body:
                                customerId present  -> 200 {"status":"ok",
                                                           "data":{"id":123,
                                                                  "received_customer_id":...,
                                                                  "received_correlation_id":...}}
                                customer_id  present -> 400 (untransformed body)
Stdlib only (no pip installs) so the image build is fully reproducible.

The backend name reported in responses is taken from the ECHO_BACKEND_NAME
environment variable (default "oss-echo"), so it is independent of the
Docker compose project name.
"""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HOST = "0.0.0.0"  # bound inside the internal Docker network only
PORT = 9000
BACKEND_NAME = os.environ.get("ECHO_BACKEND_NAME", "oss-echo")

FIXED_OK_BODY = b'{"status":"ok","data":{"id":123}}'
NOT_JSON_BODY = b"this is not json"
ERROR_BODY = b'{"status":"error","detail":"simulated upstream failure"}'


class EchoHandler(BaseHTTPRequestHandler):
    server_version = "echo-backend/1.1"

    # ---------- helpers ----------

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode("utf-8")) if raw else None
        except (ValueError, UnicodeDecodeError):
            body = raw.decode("utf-8", "replace") if raw else None
        return raw, body

    def _respond(self, code, payload):
        data = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _respond_raw(self, code, raw, content_type):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        if raw:
            self.wfile.write(raw)

    def _echo_payload(self, raw, body):
        parsed = urlparse(self.path)
        query = {k: (v[0] if len(v) == 1 else v)
                 for k, v in parse_qs(parsed.query).items()}
        headers = {k: v for k, v in self.headers.items()}
        return {
            "method": self.command,
            "path": parsed.path,
            "query": query,
            "headers": headers,
            "body": body,
            "body_raw_bytes": len(raw),
            "backend": BACKEND_NAME,
        }

    # ---------- deterministic endpoints ----------

    def _combined_echo(self):
        raw, body = self._read_body()
        if isinstance(body, dict):
            if "customerId" in body:
                self._respond(200, {
                    "status": "ok",
                    "data": {
                        "id": 123,
                        "received_customer_id": body.get("customerId"),
                        "received_correlation_id":
                            self.headers.get("X-Correlation-Id"),
                    },
                })
            elif "customer_id" in body:
                self._respond(400, {
                    "status": "error",
                    "detail": ("untransformed body received: customer_id "
                               "present, customerId missing"),
                })
            else:
                self._respond(400, {
                    "status": "error", "detail": "unexpected body shape"})
        else:
            self._respond(400, {
                "status": "error", "detail": "invalid or missing JSON body"})

    def _handle_deterministic(self):
        path = urlparse(self.path).path
        if path == "/fixed-ok":
            self._read_body()  # drain any body
            self._respond_raw(200, FIXED_OK_BODY, "application/json")
        elif path == "/empty":
            self._read_body()
            self._respond_raw(200, b"", "text/plain")
        elif path == "/not-json":
            self._read_body()
            self._respond_raw(200, NOT_JSON_BODY, "text/plain")
        elif path == "/echo-error":
            self._read_body()
            self._respond_raw(500, ERROR_BODY, "application/json")
        elif path == "/combined-echo":
            if self.command == "POST":
                self._combined_echo()
            else:
                self._read_body()
                self._respond(405, {
                    "status": "error", "detail": "POST required"})
        else:
            return False
        return True

    # ---------- HTTP methods ----------

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok",
                                "backend": BACKEND_NAME})
            return
        if self._handle_deterministic():
            return
        # default echo
        raw, _ = self._read_body()  # drain any body on GET
        self._respond(200, self._echo_payload(raw, None))

    def do_POST(self):
        if self._handle_deterministic():
            return
        raw, body = self._read_body()
        self._respond(200, self._echo_payload(raw, body))

    def log_message(self, fmt, *args):
        # keep logs quiet; access data goes to the client instead
        pass


def main():
    server = ThreadingHTTPServer((HOST, PORT), EchoHandler)
    print(f"echo backend '{BACKEND_NAME}' listening on {HOST}:{PORT}",
          flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
