"""Dev bundle only: deterministic process faults for the real Swift supervisor."""
import json
import os
from pathlib import Path
import signal
import struct
import sys
import time

home = Path(sys.argv[1])
fault = (home / "fault").read_text().strip()
(home / "pid").write_text(str(os.getpid()))
signal.signal(signal.SIGTERM, signal.SIG_IGN)

def receive():
    header = sys.stdin.buffer.read(4)
    if len(header) != 4:
        sys.exit(0)
    return json.loads(sys.stdin.buffer.read(struct.unpack(">I", header)[0]))

def send(request, result=None):
    body = json.dumps({"protocol": 1, "id": request["id"], "status": "ok", "result": result or {}}).encode()
    sys.stdout.buffer.write(struct.pack(">I", len(body)) + body)
    sys.stdout.buffer.flush()

hello = receive()
if fault == "startup-hang":
    time.sleep(60)
elif fault == "startup-malformed":
    sys.stdout.buffer.write(b"\x00\x20\x00\x00"); sys.stdout.buffer.flush(); time.sleep(60)
elif fault == "startup-partial":
    sys.stdout.buffer.write(b"\x00\x00"); sys.stdout.buffer.flush(); time.sleep(60)
elif fault == "startup-exit":
    sys.exit(2)
else:
    send(hello, {"protocol": 1, "isolated": bool(sys.flags.isolated), "pid": os.getpid(), "secret_present": any(key in os.environ for key in ("OPENAI_API_KEY", "GEMINI_API_KEY", "ANTHROPIC_API_KEY", "PYTHONPATH", "PYTHONHOME", "HTTPS_PROXY"))})
    if fault == "blocked-stdin":
        time.sleep(60)
    request = receive()
    if fault == "exit":
        sys.exit(2)
    if fault == "duplicate":
        send(request); send(request); time.sleep(60)
    if fault == "out-of-order":
        second = receive(); send(second); send(request)
        request = receive()
    if fault == "blocked-output":
        sys.stdout.buffer.write(b"!" * 2_000_000); sys.stdout.buffer.flush(); time.sleep(60)
    if fault == "cancel":
        while True:
            request = receive()
            if request["operation"] == "cancel":
                send(request)
            elif request["operation"] == "shutdown":
                send(request); break
    elif fault == "out-of-order" and request["operation"] == "shutdown":
        send(request)
    else:
        time.sleep(60)
