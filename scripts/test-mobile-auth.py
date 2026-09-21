#!/usr/bin/env python3
"""End-to-end smoke test for the production Ouros mobile OIDC contract.

The script never asks for the user's password or OTP. Authentication happens in
the system browser against Keycloak's Browser Flow. It verifies:

1. Authorization Code + PKCE S256 completes successfully.
2. The access token is issued to ouros-mobile.
3. The access token carries all mobile-facing API audiences.
4. The refresh token can mint a new access token.

Tokens are not printed. Use --output explicitly to persist them for manual API
testing; the file is created with user-only permissions when supported.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import secrets
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

ISSUER = "https://ouros-keycloak.discloud.app/realms/ouros"
CLIENT_ID = "ouros-mobile"
REDIRECT_URI = "http://127.0.0.1:8765/callback"
SCOPES = "openid ouros-identity"
EXPECTED_AUDIENCES = {
    "ms-spring-api",
    "ms-ai-server",
    "ms-telemetry-dashboard-service",
}


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def decode_jwt_payload(token: str) -> dict[str, Any]:
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        decoded = base64.urlsafe_b64decode(payload.encode("ascii"))
        value = json.loads(decoded)
    except (IndexError, ValueError, json.JSONDecodeError) as exc:
        raise RuntimeError("Keycloak returned a malformed JWT") from exc
    if not isinstance(value, dict):
        raise RuntimeError("JWT payload is not an object")
    return value


def token_post(data: dict[str, str]) -> dict[str, Any]:
    body = urllib.parse.urlencode(data).encode()
    request = urllib.request.Request(
        f"{ISSUER}/protocol/openid-connect/token",
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        try:
            error = json.loads(exc.read().decode("utf-8", errors="replace"))
        except json.JSONDecodeError:
            error = {"error": "http_error", "status": exc.code}
        raise RuntimeError(f"Token endpoint rejected the request: {error}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Could not reach Keycloak: {exc.reason}") from exc
    if not isinstance(payload, dict):
        raise RuntimeError("Token endpoint returned an unexpected response")
    return payload


def audience_set(claims: dict[str, Any]) -> set[str]:
    aud = claims.get("aud")
    if isinstance(aud, str):
        return {aud}
    if isinstance(aud, list) and all(isinstance(item, str) for item in aud):
        return set(aud)
    return set()


def validate_access_token(token: str, *, label: str) -> dict[str, Any]:
    claims = decode_jwt_payload(token)
    audiences = audience_set(claims)
    missing = EXPECTED_AUDIENCES - audiences

    if claims.get("iss") != ISSUER:
        raise RuntimeError(
            f"{label}: unexpected issuer {claims.get('iss')!r}; expected {ISSUER!r}"
        )
    if claims.get("azp") != CLIENT_ID:
        raise RuntimeError(
            f"{label}: unexpected azp {claims.get('azp')!r}; expected {CLIENT_ID!r}"
        )
    if missing:
        raise RuntimeError(
            f"{label}: missing audiences: {', '.join(sorted(missing))}; "
            f"received: {', '.join(sorted(audiences)) or '<none>'}"
        )

    return claims


class CallbackState:
    query: dict[str, list[str]] | None = None


class CallbackHandler(BaseHTTPRequestHandler):
    server_version = "OurosMobileAuthTest/1.0"

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/callback":
            self.send_error(404)
            return

        CallbackState.query = urllib.parse.parse_qs(parsed.query)
        body = (
            "<!doctype html><meta charset='utf-8'>"
            "<title>Ouros auth test</title>"
            "<h1>Ouros mobile auth test</h1>"
            "<p>Callback recebido. Pode voltar para o terminal.</p>"
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        return


def wait_for_callback(timeout: float) -> dict[str, list[str]]:
    server = ThreadingHTTPServer(("127.0.0.1", 8765), CallbackHandler)
    server.timeout = timeout
    thread = threading.Thread(target=server.handle_request, daemon=True)
    thread.start()
    thread.join(timeout + 1)
    server.server_close()

    if thread.is_alive() or CallbackState.query is None:
        raise RuntimeError("Timed out waiting for the browser callback")
    return CallbackState.query


def write_tokens(path: Path, tokens: dict[str, Any]) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(tokens, handle, indent=2)
        handle.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--no-browser",
        action="store_true",
        help="print the authorization URL without opening the system browser",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=300,
        help="seconds to wait for login + email OTP (default: 300)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="explicitly save token responses to a local mode-0600 JSON file",
    )
    args = parser.parse_args()

    verifier = secrets.token_urlsafe(64)
    challenge = b64url(hashlib.sha256(verifier.encode("ascii")).digest())
    state = secrets.token_urlsafe(24)

    params = {
        "client_id": CLIENT_ID,
        "response_type": "code",
        "redirect_uri": REDIRECT_URI,
        "scope": SCOPES,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
    }
    auth_url = (
        f"{ISSUER}/protocol/openid-connect/auth?"
        + urllib.parse.urlencode(params)
    )

    print("[1/4] Abrindo o Browser Flow do Keycloak...")
    print("      Faça login e conclua o OTP por e-mail.")
    if args.no_browser or not webbrowser.open(auth_url):
        print("\nAbra esta URL no navegador:\n")
        print(auth_url)
        print()

    callback = wait_for_callback(args.timeout)

    if "error" in callback:
        description = callback.get("error_description", [""])[0]
        raise RuntimeError(
            f"Authorization failed: {callback['error'][0]} {description}".strip()
        )

    returned_state = callback.get("state", [""])[0]
    code = callback.get("code", [""])[0]
    if not secrets.compare_digest(returned_state, state):
        raise RuntimeError("OAuth state mismatch")
    if not code:
        raise RuntimeError("Authorization callback did not contain a code")

    print("[2/4] Trocando authorization code por tokens com PKCE...")
    tokens = token_post(
        {
            "grant_type": "authorization_code",
            "client_id": CLIENT_ID,
            "redirect_uri": REDIRECT_URI,
            "code": code,
            "code_verifier": verifier,
        }
    )

    access_token = tokens.get("access_token")
    refresh_token = tokens.get("refresh_token")
    id_token = tokens.get("id_token")
    if not isinstance(access_token, str) or not access_token:
        raise RuntimeError("Keycloak did not return access_token")
    if not isinstance(refresh_token, str) or not refresh_token:
        raise RuntimeError("Keycloak did not return refresh_token")
    if not isinstance(id_token, str) or not id_token:
        raise RuntimeError("Keycloak did not return id_token")

    claims = validate_access_token(access_token, label="initial access token")
    print("[3/4] Access token válido para o contrato mobile:")
    print(f"      sub={claims.get('sub')}")
    print(f"      account_type={claims.get('account_type')}")
    print(f"      database_id={claims.get('database_id')}")
    print(f"      audiences={', '.join(sorted(audience_set(claims)))}")

    refreshed = token_post(
        {
            "grant_type": "refresh_token",
            "client_id": CLIENT_ID,
            "refresh_token": refresh_token,
        }
    )
    refreshed_access = refreshed.get("access_token")
    if not isinstance(refreshed_access, str) or not refreshed_access:
        raise RuntimeError("Refresh response did not contain access_token")
    refreshed_claims = validate_access_token(
        refreshed_access,
        label="refreshed access token",
    )
    if refreshed_claims.get("sub") != claims.get("sub"):
        raise RuntimeError("Refresh changed the authenticated subject")

    print("[4/4] Refresh token válido e novo access token emitido.")

    if args.output:
        write_tokens(
            args.output,
            {
                "initial": tokens,
                "refreshed": refreshed,
            },
        )
        print(f"      Tokens salvos explicitamente em {args.output} (modo 0600).")

    print("\nOK: senha + OTP -> code + PKCE -> access/refresh/id token -> refresh.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nCancelado.", file=sys.stderr)
        raise SystemExit(130)
    except Exception as exc:
        print(f"\nERRO: {exc}", file=sys.stderr)
        raise SystemExit(1)
