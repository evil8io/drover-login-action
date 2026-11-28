#!/usr/bin/env python3
"""A forward proxy for the bats tests. The proxy answers 501 to a GET or a POST and does not log the
request.

The proxy appends one line CONNECT <host>:<port> per request to PROXY_LOG.
"""

import os
import select
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

IDLE_SECONDS = 5


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_CONNECT(self):
        with open(os.environ["PROXY_LOG"], "a", encoding="utf-8") as log:
            log.write(f"CONNECT {self.path}\n")
        host, port = self.path.rsplit(":", 1)
        upstream = socket.create_connection((host, int(port)))
        self.send_response(200, "Connection established")
        self.end_headers()
        client = self.connection
        try:
            while True:
                ready, _, _ = select.select([client, upstream], [], [], IDLE_SECONDS)
                if not ready:
                    return
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    (upstream if source is client else client).sendall(data)
        finally:
            upstream.close()


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(os.environ["PROXY_PORT_FILE"], "w", encoding="utf-8") as port_file:
        port_file.write(str(server.server_address[1]))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
