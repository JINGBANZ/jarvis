"""Non-GUI framed peer: shutdown waits for an in-flight converter launch handshake."""
import json
import os
from pathlib import Path
import runpy
import struct
import subprocess
import sys
import threading
import time

launch_owned = runpy.run_path(sys.argv[1])['launch_owned']
pidfile = Path(sys.argv[2])
child = None
failure = []


def launch_converter():
    global child
    try:
        child = launch_owned(['/bin/sh', '-c', 'echo $$ > "$1"; exec /bin/sleep 5', 'fixture', str(pidfile)],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except BaseException as error:
        failure.append(error)


def reply(request):
    body = json.dumps({'protocol': 1, 'id': request['id'], 'status': 'ok', 'result': {}}).encode()
    sys.stdout.buffer.write(struct.pack('>I', len(body)) + body)
    sys.stdout.buffer.flush()


for operation in ('hello', 'shutdown'):
    header = sys.stdin.buffer.read(4)
    request = json.loads(sys.stdin.buffer.read(struct.unpack('>I', header)[0]))
    assert request['operation'] == operation
    if operation == 'hello':
        worker = threading.Thread(target=launch_converter)
        worker.start()
        deadline = time.monotonic() + 3
        while not pidfile.exists() and time.monotonic() < deadline:
            time.sleep(.005)
        assert pidfile.exists()
    else:
        worker.join(timeout=3)
        assert not worker.is_alive() and not failure
        if child.poll() is None:
            child.terminate()
        child.wait(timeout=3)
    reply(request)
