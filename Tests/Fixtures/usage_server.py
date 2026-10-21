"""Loopback-only Codex quota fixture. Never receives real credentials."""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from loopback_server import LoopbackHTTPServer


class Handler(BaseHTTPRequestHandler):
    counters = {}

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/should-not-follow")
            self.end_headers()
            return
        account = self.headers.get("ChatGPT-Account-Id", "")
        attempt = self.counters.get(account, 0) + 1
        self.counters[account] = attempt
        status = 200
        if account == "workspace-b" and attempt == 2:
            status = 503
            payload = {"error": "fixture unavailable"}
        else:
            payload = {
                "account_id": account,
                "plan_type": "plus" if account == "workspace-a" else "pro",
                "rate_limit": {
                    "primary_window": {
                        "used_percent": 20 if account == "workspace-a" else (70 if attempt == 1 else 85),
                        "reset_at": int(time.time()) + 7200,
                        "limit_window_seconds": 18000,
                    },
                    "secondary_window": {
                        "used_percent": 50,
                        "reset_at": int(time.time()) + 172800,
                        "limit_window_seconds": 604800,
                    },
                },
            }
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


parser = argparse.ArgumentParser()
parser.add_argument("--ready-file", required=True)
args = parser.parse_args()
server = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
Path(args.ready_file).write_text(json.dumps({"port": server.server_port}))
server.serve_forever()
