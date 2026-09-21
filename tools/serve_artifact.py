#!/usr/bin/env python3
"""Temporarily serve one explicit build file to one explicitly allowed router."""
import argparse
import http.server
import pathlib
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", type=pathlib.Path, required=True)
    parser.add_argument("--bind", required=True)
    parser.add_argument("--allow", action="append", required=True)
    parser.add_argument("--port", type=int, default=18880)
    parser.add_argument("--duration", type=int, default=900)
    args = parser.parse_args()
    payload = args.file.read_bytes()
    allowed = set(args.allow)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.client_address[0] not in allowed:
                self.send_error(403)
                return
            if self.path != "/artifact.lua":
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    with http.server.HTTPServer((args.bind, args.port), Handler) as server:
        server.timeout = 1
        deadline = time.monotonic() + args.duration
        print(f"Serving one artifact ({len(payload)} bytes), allowed peers: {sorted(allowed)}", flush=True)
        while time.monotonic() < deadline:
            server.handle_request()


if __name__ == "__main__":
    main()
