#!/usr/bin/env python3
"""Loopback-only native Foundation integration fixture (no dependencies)."""
import http.server
import threading

PAYLOAD = b"local deterministic payload"

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        if self.path == "/hold":
            threading.Event().wait(15)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))) or PAYLOAD
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
    do_POST = do_GET
    do_PUT = do_GET
    def log_message(self, *_):
        pass

if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 18764), Handler)
    server.daemon_threads = True
    print("READY http://127.0.0.1:18764", flush=True)
    server.serve_forever()
