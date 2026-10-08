#!/usr/bin/env python3
"""Local fixture server for fastup tests.

Usage: fixture_server.py <root-dir> <port-file> <request-log>

Serves files under <root-dir>. Query parameters:
  throttle=<KiB/s>   send the body at roughly this rate (64 KiB chunks)
  status=<code>      reply with this status and an HTML body instead of the file
  norange=1          ignore Range headers (always 200 + full body)
  redirect=<url>     reply 302 to <url>
  notype=1           send no Content-Type header
Every request is appended to <request-log> as
"<METHOD> <path?query> <Range or -> auth=<Authorization or ->".
Writes the chosen port to <port-file> once listening.
"""
import http.server
import os
import socketserver
import sys
import time
import urllib.parse

ROOT, PORT_FILE, LOG = sys.argv[1], sys.argv[2], sys.argv[3]
CHUNK = 64 * 1024


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.handle_req(head=True)

    def do_GET(self):
        self.handle_req(head=False)

    def handle_req(self, head):
        u = urllib.parse.urlsplit(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        with open(LOG, "a") as f:
            f.write(f"{self.command} {self.path} {self.headers.get('Range', '-')} "
                    f"auth={self.headers.get('Authorization', '-')}\n")

        if "redirect" in q:
            self.send_response(302)
            self.send_header("Location", q["redirect"])
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if "status" in q:
            body = b"<html><body>error page</body></html>"
            self.send_response(int(q["status"]))
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head:
                self.wfile.write(body)
            return

        path = os.path.normpath(os.path.join(ROOT, urllib.parse.unquote(u.path).lstrip("/")))
        if not path.startswith(os.path.abspath(ROOT)) or not os.path.isfile(path):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        with open(path, "rb") as f:
            data = f.read()
        start, end = 0, len(data) - 1
        rng = self.headers.get("Range")
        partial = False
        if rng and rng.startswith("bytes=") and q.get("norange") != "1":
            a, _, b = rng[6:].partition("-")
            start = int(a) if a else 0
            end = min(int(b), len(data) - 1) if b else len(data) - 1
            partial = True
        body = data[start:end + 1]

        self.send_response(206 if partial else 200)
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        if q.get("notype") != "1":
            self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        if head:
            return
        rate = float(q["throttle"]) * 1024 if "throttle" in q else 0
        try:
            for i in range(0, len(body), CHUNK):
                self.wfile.write(body[i:i + CHUNK])
                if rate:
                    time.sleep(CHUNK / rate)
        except (BrokenPipeError, ConnectionResetError):
            pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


srv = Server(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
