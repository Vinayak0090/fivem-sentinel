#!/usr/bin/env python3
"""Live dashboard server for fivem-sentinel on Linux.

Serves the shared dashboard page and the live.json the monitor writes each
cycle. Standard library only.

    python3 dashboard.py [--port 8123] [--bind 127.0.0.1] [--logs ./logs]

Keep the bind on 127.0.0.1 unless you know what you are doing; if you expose
it, restrict the port to your own IP in the firewall - there is no auth.
"""
import argparse
import http.server
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(os.path.dirname(HERE), "assets")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8123)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--logs", default=os.path.join(HERE, "logs"))
    args = ap.parse_args()

    dash_path = os.path.join(ASSETS, "dashboard.html")
    chart_path = os.path.join(ASSETS, "chart.umd.min.js")
    live_path = os.path.join(args.logs, "live.json")

    if not os.path.isfile(dash_path):
        sys.exit(f"dashboard.html not found at {dash_path}")

    class Handler(http.server.BaseHTTPRequestHandler):
        def _send(self, code, ctype, body):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            try:
                if self.path.rstrip("/").endswith("data"):
                    try:
                        with open(live_path, "rb") as f:
                            body = f.read()
                    except OSError:
                        body = b'{"now":{},"hist":[],"alerts":[]}'
                    self._send(200, "application/json", body)
                elif self.path.endswith("chart.js"):
                    try:
                        with open(chart_path, "rb") as f:
                            body = f.read()
                    except OSError:
                        body = b""
                    self._send(200, "text/javascript", body)
                else:
                    with open(dash_path, "rb") as f:
                        self._send(200, "text/html; charset=utf-8", f.read())
            except BrokenPipeError:
                pass

        def log_message(self, *a):  # keep journald quiet
            pass

    srv = http.server.ThreadingHTTPServer((args.bind, args.port), Handler)
    print(f"fivem-sentinel dashboard on http://{args.bind}:{args.port} (live data: {live_path})")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
