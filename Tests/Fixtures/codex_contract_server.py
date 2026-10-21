"""Local Codex OAuth/usage contract fixture, pinned to the audited CodexBar shapes.

Only fake credentials are accepted. Requests are traced without credential values.
"""
import argparse
import base64
import json
import threading
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from loopback_server import LoopbackHTTPServer


def access_token():
    claims = {
        "sub": "user-a", "exp": int(time.time()) + 3600,
        "https://api.openai.com/auth": {"chatgpt_account_id": "workspace-a", "chatgpt_user_id": "user-a"},
    }
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return "mock-fresh." + payload + ".fake-signature"


class Handler(BaseHTTPRequestHandler):
    traces = []
    exchanges = 0
    lock = threading.Lock()

    def log_message(self, *_):
        pass

    def trace(self, extra=None):
        with self.lock:
            self.traces.append({
                "method": self.command, "path": self.path,
                "accountHeader": self.headers.get("ChatGPT-Account-Id"),
                "accept": self.headers.get("Accept"),
                "userAgent": self.headers.get("User-Agent"),
                "hasCookie": self.headers.get("Cookie") is not None,
                "fakeBearer": self.headers.get("Authorization", "").startswith(("Bearer header.", "Bearer mock-fresh.")),
                **(extra or {}),
            })

    def reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        valid = (self.path == "/oauth/token" and self.headers.get("Content-Type") == "application/json"
                 and body.get("client_id") == "app_EMoamEEZ73f0CkXaXp7hrann"
                 and body.get("grant_type") == "refresh_token"
                 and body.get("scope") == "openid profile email"
                 and body.get("refresh_token") == "loopback-r0")
        self.trace({"oauthContractValid": valid})
        if not valid:
            self.reply(400, {"error": "invalid_client"})
            return
        with self.lock:
            type(self).exchanges += 1
            exchange = self.exchanges
        if exchange > 1:
            self.reply(400, {"error": {"code": "refresh_token_reused"}})
            return
        time.sleep(0.15)
        self.reply(200, {"access_token": access_token(), "refresh_token": "loopback-r1", "token_type": "Bearer"})

    def do_GET(self):
        if self.path == "/audit":
            with self.lock:
                data = list(self.traces)
            self.reply(200, {"requests": data})
            return
        self.trace()
        if self.path == "/redirect-contract":
            self.send_response(302)
            self.send_header("Location", "/unexpected-target")
            self.end_headers()
            return
        bearer = self.headers.get("Authorization", "")
        if not bearer.startswith(("Bearer header.", "Bearer mock-fresh.")):
            self.reply(401, {"error": "fixture accepts fake bearer only"})
            return
        account = self.headers.get("ChatGPT-Account-Id", "")
        if self.path.endswith("/monthly-usage"):
            expected_path = "/backend-api/accounts/" + account + "/spend-controls/current-user/monthly-usage"
            if self.path != expected_path:
                self.reply(403, {"error": "workspace scope mismatch"})
            elif account == "workspace-monthly-failure":
                self.reply(503, {"error": "secret-sentinel-must-not-be-displayed"})
            else:
                self.reply(200, {
                    "account_id": None, "accountId": account,
                    "current_month_usage": "200",
                    "effective_monthly_limit": {"limit": "1000", "enforcement_mode": "hard"},
                })
            return
        if self.path != "/backend-api/wham/usage":
            self.reply(404, {})
            return
        if account == "workspace-forbidden":
            self.reply(403, {"error": "secret-sentinel-must-not-be-displayed"})
            return
        if account == "workspace-throttled":
            self.reply(429, {"error": "secret-sentinel-must-not-be-displayed"})
            return
        now = int(time.time())
        payload = {
            "account_id": None, "accountId": "other-workspace" if account == "workspace-bad-identity" else account,
            "plan_type": "team", "spend_control": {},
            "rate_limit": {
                "primary_window": {"used_percent": 61, "reset_at": now + 172800, "limit_window_seconds": 604800},
                "secondary_window": {"used_percent": 23, "reset_at": now + 7200, "limit_window_seconds": 18000},
            },
        }
        if account == "workspace-a":
            payload["additional_rate_limits"] = [None, "broken", 42, {
                "limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex-spark",
                "rate_limit": {"primary_window": {"used_percent": 9, "reset_at": now + 7200, "limit_window_seconds": 18000}},
            }]
        self.reply(200, payload)


parser = argparse.ArgumentParser()
parser.add_argument("--ready-file", required=True)
args = parser.parse_args()
server = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
Path(args.ready_file).write_text(json.dumps({"port": server.server_port}))
server.serve_forever()
