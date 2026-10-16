"""Offline contracts run with the bundled interpreter by the ordinary Gate."""
import json
import os
from pathlib import Path
import select
import signal
import time
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid

HELPER = Path(__file__).with_name("helper.py")


class HelperContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        bootstrap = "import faulthandler,runpy,signal,sys;faulthandler.register(signal.SIGUSR1);sys.argv=sys.argv[1:];runpy.run_path(sys.argv[0],run_name='__main__')"
        self.child = subprocess.Popen([sys.executable, "-I", "-B", "-c", bootstrap, str(HELPER), str(self.root / "store")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={"PATH": "/usr/bin:/bin", "HOME": str(self.root), "OPENAI_API_KEY": "must-not-be-read", "PYTHONPATH": str(self.root)})
        self.addCleanup(self.close_child)
        self.session = str(uuid.uuid4())
        self.assertTrue(self.call("hello", timeout=30)["result"]["isolated"])

    def close_child(self):
        if self.child.poll() is None:
            self.child.kill()
        self.child.communicate(timeout=5)
        self.temporary.cleanup()

    def read_exact(self, count, deadline):
        result = bytearray()
        while len(result) < count:
            if not select.select([self.child.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                self.child.send_signal(signal.SIGUSR1)
                time.sleep(.1)
                diagnostics = b""
                while select.select([self.child.stderr], [], [], .1)[0]:
                    piece = os.read(self.child.stderr.fileno(), 65536)
                    if not piece: break
                    diagnostics += piece
                self.fail("bounded response; helper stack:\n" + diagnostics.decode(errors="replace"))
            piece = os.read(self.child.stdout.fileno(), count - len(result))
            self.assertTrue(piece, "unexpected EOF")
            result.extend(piece)
        return result

    def call(self, operation, payload=None, split=False, timeout=2):
        identifier = str(uuid.uuid4())
        body = json.dumps({"protocol": 1, "id": identifier, "operation": operation, "session_id": self.session, "payload": payload or {}}).encode()
        frame = struct.pack(">I", len(body)) + body
        if split:
            self.child.stdin.write(frame[:2]); self.child.stdin.flush()
            self.child.stdin.write(frame[2:])
        else:
            self.child.stdin.write(frame)
        self.child.stdin.flush()
        deadline = time.monotonic() + timeout
        length = struct.unpack(">I", self.read_exact(4, deadline))[0]
        reply = json.loads(self.read_exact(length, deadline))
        self.assertEqual(reply["id"], identifier)
        self.assertEqual(reply["protocol"], 1)
        return reply

    def configure(self, name="fixture.txt"):
        key = str(uuid.uuid4())
        self.assertEqual(self.call("configure", {"root": str(self.root), "documents": [{"document_id": key, "name": name}]})["status"], "ok")
        return key

    def test_real_read_search_private_storage_and_partial_frame(self):
        hello = self.call("hello", split=True)
        self.assertTrue(hello["result"]["isolated"])
        (self.root / "fixture.txt").write_text("Uniquequasar lexical retrieval.\n" + "😀e\u0301" * 6000)
        key = self.configure()
        read = self.call("read", {"document_id": key})
        self.assertEqual(len(read["result"]["text"]), 16000)
        result = self.call("search", {"query": "uniquequasar"})
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["result"]["hits"][0]["document_id"], key)
        for path in [self.root / "store", *(self.root / "store").rglob("*")]:
            self.assertEqual(path.stat().st_mode & 0o077, 0, str(path))
        self.assertEqual(self.call("release")["status"], "ok")
        self.assertEqual(self.call("read", {"document_id": key})["status"], "unavailable")
        self.call("shutdown")
        self.assertEqual(self.child.wait(timeout=5), 0)

    def test_fifo_is_rejected_without_blocking(self):
        os.mkfifo(self.root / "fixture.txt", 0o600)
        key = self.configure()
        self.assertEqual(self.call("read", {"document_id": key})["status"], "unavailable")
        self.call("shutdown")
        self.child.wait(timeout=5)

    def test_oversized_frame_exits(self):
        self.child.stdin.write(struct.pack(">I", 1_048_577)); self.child.stdin.flush()
        self.assertEqual(self.child.wait(timeout=15), 2)

    def test_truncated_frame_exits(self):
        self.child.stdin.write(b"\0\0"); self.child.stdin.close()
        self.assertEqual(self.child.wait(timeout=15), 2)
        self.child.stdin = None


if __name__ == "__main__":
    unittest.main()
