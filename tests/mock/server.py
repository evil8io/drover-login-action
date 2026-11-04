#!/usr/bin/env python3
"""This file is a mock of the GitHub OIDC endpoint and of OpenBao, for the tests of the action.

The server writes its port to the file MOCK_PORT_FILE. It writes one JSON line per request to
the file MOCK_LOG. The file MOCK_CONFIG, when it exists, is a JSON document that the server
reads at each request. The document can contain these keys:

- request_token: the bearer token that the OIDC endpoint expects. Default: request-token.
- client_token: the OpenBao token that the login endpoint returns. Default: hvb.mock-client-token.
- oidc_status, login_status, creds_status: the HTTP status of each endpoint. Default: 200.
  With another status, the endpoint returns an error document.
- oidc_body: when the key is set, the OIDC endpoint returns this text as HTML with the status 200.
"""

import base64
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

SA_TOKEN = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJtb2NrIn0.mock-service-account-token"
LOGIN_PATH = re.compile(r"^/v1/auth/jwt/(?P<issuer>[^/]+)/login$")
CREDS_PATH = re.compile(r"^/v1/kubernetes/(?P<cluster>[^/]+)/creds/(?P<name>[^/]+)$")
DEFAULTS = {
    "request_token": "request-token",
    "client_token": "hvb.mock-client-token",
    "oidc_status": 200,
    "login_status": 200,
    "creds_status": 200,
    "oidc_body": None,
}


def config():
    path = os.environ.get("MOCK_CONFIG", "")
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as file:
            return DEFAULTS | json.load(file)
    return DEFAULTS


def fake_jwt(claims):
    def segment(data):
        return base64.urlsafe_b64encode(json.dumps(data).encode()).decode().rstrip("=")

    return f"{segment({'alg': 'none'})}.{segment(claims)}.mock-signature"


def lease_seconds(ttl):
    """Returns the lease of a token request: the ttl of the request, or 900 when the request does
    not have a ttl."""
    if not ttl:
        return 900
    units = {"s": 1, "m": 60, "h": 3600}
    if ttl[-1] in units:
        return int(ttl[:-1]) * units[ttl[-1]]
    return int(ttl)


def jwt_claims(token):
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except (IndexError, ValueError):
        return None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def record(self, body):
        entry = {
            "method": self.command,
            "path": urlsplit(self.path).path,
            "query": {k: v[0] for k, v in parse_qs(urlsplit(self.path).query).items()},
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body": body,
        }
        if isinstance(body, dict) and "jwt" in body:
            entry["jwt_claims"] = jwt_claims(body["jwt"])
        with open(os.environ["MOCK_LOG"], "a", encoding="utf-8") as log:
            log.write(json.dumps(entry) + "\n")

    def answer_raw(self, status, data, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def answer(self, status, document):
        self.answer_raw(status, json.dumps(document).encode(), "application/json")

    def do_GET(self):
        self.record(None)
        settings = config()
        parts = urlsplit(self.path)
        if parts.path != "/oidc":
            return self.answer(404, {"errors": ["no handler for the route"]})
        if self.headers.get("Authorization") != f"bearer {settings['request_token']}":
            return self.answer(401, {"message": "the request token is wrong"})
        if settings["oidc_body"] is not None:
            return self.answer_raw(200, settings["oidc_body"].encode(), "text/html")
        if settings["oidc_status"] != 200:
            return self.answer(
                settings["oidc_status"], {"message": "the OIDC endpoint failed"}
            )
        audience = parse_qs(parts.query).get("audience", [""])[0]
        return self.answer(
            200, {"value": fake_jwt({"aud": audience, "repository_id": "1"})}
        )

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode()
        try:
            body = json.loads(raw) if raw else {}
        except ValueError:
            body = raw
        self.record(body)
        settings = config()
        path = urlsplit(self.path).path

        login = LOGIN_PATH.match(path)
        if login:
            if (
                not isinstance(body, dict)
                or not body.get("role")
                or not body.get("jwt")
            ):
                return self.answer(400, {"errors": ["missing role or jwt"]})
            if settings["login_status"] != 200:
                # This is the multi-line format of an OpenBao error.
                return self.answer(
                    settings["login_status"],
                    {"errors": ["1 error occurred:\n\t* permission denied\n\n"]},
                )
            return self.answer(
                200,
                {
                    "auth": {
                        "client_token": settings["client_token"],
                        "lease_duration": 300,
                    }
                },
            )

        creds = CREDS_PATH.match(path)
        if creds:
            if self.headers.get("X-Vault-Token") != settings["client_token"]:
                return self.answer(403, {"errors": ["permission denied"]})
            if not isinstance(body, dict) or not body.get("kubernetes_namespace"):
                return self.answer(
                    400, {"errors": ["'kubernetes_namespace' is required"]}
                )
            if settings["creds_status"] != 200:
                return self.answer(
                    settings["creds_status"], {"errors": ["the role does not exist"]}
                )
            name = creds.group("name")
            return self.answer(
                200,
                {
                    "lease_duration": lease_seconds(body.get("ttl")),
                    "data": {
                        "service_account_name": name.split("-", 1)[1]
                        if "-" in name
                        else name,
                        "service_account_namespace": body["kubernetes_namespace"],
                        "service_account_token": SA_TOKEN,
                    },
                },
            )

        return self.answer(404, {"errors": ["no handler for the route"]})


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(os.environ["MOCK_PORT_FILE"], "w", encoding="utf-8") as port_file:
        port_file.write(str(server.server_address[1]))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
