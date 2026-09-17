import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

IDENTITY = {
    "id": 42,
    "email": "ci-user@example.com",
    "account_type": "farm_owner",
    "realm_role": "farm_owner",
    "name": "CI User",
    "farm_id": 7,
    "enterprise_id": None,
    "first_access": False,
}


class Handler(BaseHTTPRequestHandler):
    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        value = self.headers.get("Authorization", "")
        return value.startswith("Bearer ") and len(value) > len("Bearer ")

    def do_GET(self):
        if not self._authorized():
            self._json(401, {"detail": "unauthorized"})
            return

        parsed = urlparse(self.path)
        if parsed.path == "/internal/v1/identities/by-email":
            email = parse_qs(parsed.query).get("email", [""])[0].lower()
            self._json(200, IDENTITY) if email == IDENTITY["email"] else self._json(404, {"detail": "not found"})
            return

        if parsed.path == "/internal/v1/identities/farm_owner/42":
            self._json(200, IDENTITY)
            return

        self._json(404, {"detail": "not found"})

    def do_POST(self):
        if not self._authorized():
            self._json(401, {"detail": "unauthorized"})
            return
        if self.path != "/internal/v1/credentials/verify":
            self._json(404, {"detail": "not found"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length) or b"{}")
        if (
            payload.get("email", "").lower() == IDENTITY["email"]
            and payload.get("password") == "ci-password"
            and payload.get("account_type") == "farm_owner"
        ):
            self._json(200, {"authenticated": True, "identity": IDENTITY})
        else:
            self._json(401, {"detail": "Credenciais inválidas."})

    def log_message(self, _format, *_args):
        return


ThreadingHTTPServer(("0.0.0.0", 8081), Handler).serve_forever()
