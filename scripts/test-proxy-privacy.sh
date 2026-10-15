#!/usr/bin/env bash
# Exercise startup and no-browser OAuth with empty credentials behind a recording HTTP proxy.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
if (( $# > 1 )); then echo "usage: $0 [helper-executable]" >&2; exit 2; fi
if (( $# == 1 )); then
  HELPER="$1"
else
  source scripts/lib/cliproxyapi.sh
  build_cliproxyapi
  HELPER="$CLIPROXYAPI_BUILT_DIRECTORY/cliproxyapi"
fi
python3 - "$HELPER" <<'PY'
import http.server
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import urllib.parse

helper = str(Path(sys.argv[1]).resolve(strict=True))
requests = queue.Queue()

class Recorder(http.server.BaseHTTPRequestHandler):
    def do_CONNECT(self):
        self.record()

    def do_GET(self):
        self.record()

    def record(self):
        requests.put(self.path)
        self.send_error(502)

    def log_message(self, *args):
        pass

def free_port():
    with socket.socket() as connection:
        connection.bind(("127.0.0.1", 0))
        return connection.getsockname()[1]

def drain():
    result = []
    while not requests.empty():
        result.append(requests.get_nowait())
    return result

base = Path(".build/proxy-privacy")
base.mkdir(parents=True, exist_ok=True)
failures = []
with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Recorder) as recorder:
    threading.Thread(target=recorder.serve_forever, daemon=True).start()
    proxy = f"http://127.0.0.1:{recorder.server_port}"
    for mode in ("server", "codex", "claude"):
        with tempfile.TemporaryDirectory(prefix=mode + "-", dir=base) as folder:
            root = Path(folder).resolve()
            auth = root / "auth"
            auth.mkdir(mode=0o700)
            port = free_port()
            config = root / "config.yaml"
            config.write_text(f'''host: "127.0.0.1"
port: {port}
auth-dir: "{auth}"
commercial-mode: true
logging-to-file: false
usage-statistics-enabled: false
disable-image-generation: true
remote-management:
  disable-control-panel: true
  disable-auto-update-panel: true
''')
            config.chmod(0o600)
            env = {"PATH": "/usr/bin:/bin", "HOME": str(root),
                   "HTTP_PROXY": proxy, "HTTPS_PROXY": proxy, "ALL_PROXY": proxy,
                   "http_proxy": proxy, "https_proxy": proxy, "all_proxy": proxy,
                   "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost"}
            args = [helper, "-config", str(config), "-local-model"]
            if mode != "server":
                args += [f"-{mode}-login", "-no-browser", "-oauth-callback-port", str(free_port())]
            drain()
            process = subprocess.Popen(args, cwd=root, env=env, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            output = queue.Queue()

            def read_output(pipe=process.stdout, lines=output):
                for line in pipe:
                    lines.put(line)

            threading.Thread(target=read_output, daemon=True).start()
            ready = False
            deadline = time.monotonic() + 15
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            try:
                while time.monotonic() < deadline and process.poll() is None:
                    if mode == "server":
                        try:
                            with opener.open(f"http://127.0.0.1:{port}/v1/models", timeout=0.2) as response:
                                ready = response.status == 200
                        except (OSError, urllib.error.URLError):
                            pass
                    else:
                        while not output.empty():
                            if f"Waiting for {mode.capitalize()} authentication callback" in output.get_nowait():
                                ready = True
                    if ready:
                        break
                    time.sleep(0.05)
                # The unwanted updater starts immediately; allow its worker to reach the proxy.
                time.sleep(2)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                process.stdout.close()
            traffic = drain()
            print(f"{mode}: ready={ready}, unrelated HTTP requests={len(traffic)}")
            for target in traffic:
                print("  destination: " + (urllib.parse.urlsplit(target).hostname or target.split('/')[0]))
            if not ready or traffic:
                failures.append(mode)
    recorder.shutdown()
if failures:
    sys.exit("Helper privacy regression: " + ", ".join(failures))
print("Helper privacy checks passed (empty-auth startup and Codex/Claude OAuth initiation).")
PY
