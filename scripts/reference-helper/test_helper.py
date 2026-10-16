"""Host-only framed contracts for the native executable, run by the ordinary Gate."""
import json
import os
from pathlib import Path
import select
import time
import struct
import subprocess
import sys
import tempfile
import sqlite3
import unittest
import uuid

HELPER = Path(sys.argv.pop(1)).resolve()


class HelperContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.child = self.launch()
        self.addCleanup(self.close_child)
        self.session = str(uuid.uuid4())
        hello = self.call("hello", timeout=30)["result"]
        self.assertTrue(hello["isolated"])
        self.assertFalse(hello["secret_present"])
        self.assertEqual(hello["engine"], "sqlite-fts5")

    def launch(self):
        # Mirrors the app supervisor's allowlist; hostile ambient values never reach the child.
        return subprocess.Popen([str(HELPER), str(self.root / "store")], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env={"PATH": "/usr/bin:/bin", "HOME": str(self.root / "store"), "LANG": "en_US.UTF-8"},
                                cwd=self.root)

    def close_child(self):
        if self.child.poll() is None:
            self.child.kill()
        self.child.communicate(timeout=5)
        self.temporary.cleanup()

    def read_exact(self, count, deadline):
        result = bytearray()
        while len(result) < count:
            if not select.select([self.child.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                self.fail("bounded native helper response")
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

    def configure(self, name="fixture.txt", key=None):
        key = key or str(uuid.uuid4())
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
        self.assertEqual(len(result["result"]["hits"][0]["text"]), 2000)
        page = self.call("read", {"document_id": key, "offset": 16000})["result"]
        self.assertEqual(page["total_scalars"], len((self.root / "fixture.txt").read_text()))
        self.assertEqual(page["next_offset"], page["total_scalars"])
        for path in [self.root / "store", *(self.root / "store").rglob("*")]:
            self.assertEqual(path.stat().st_mode & 0o077, 0, str(path))
        self.assertEqual(self.call("release")["status"], "ok")
        self.assertEqual(self.call("read", {"document_id": key})["status"], "unavailable")
        self.call("shutdown")
        self.assertEqual(self.child.wait(timeout=5), 0)

    def test_persisted_fts_reopen_and_refresh(self):
        fixture = self.root / "fixture.txt"
        fixture.write_text("Uniquequasar lexical retrieval.")
        key = self.configure()
        self.assertEqual(self.call("search", {"query": "uniquequasar"})["result"]["hits"][0]["document_id"], key)
        self.call("shutdown")
        self.assertEqual(self.child.wait(timeout=5), 0)
        self.child.communicate(timeout=5)
        # Query the actual persisted FTS index with a fresh SQLite connection and no source reads.
        with sqlite3.connect(self.root / "store/control.sqlite") as database:
            self.assertEqual(database.execute("SELECT document_id FROM chunks WHERE chunks MATCH ?", ('"uniquequasar"',)).fetchall(), [(key,)])
        database.close()
        self.child = self.launch()
        self.assertEqual(self.call("hello")["result"]["engine"], "sqlite-fts5")
        self.configure(key=key)
        self.assertEqual(self.call("search", {"query": "uniquequasar"})["result"]["hits"][0]["document_id"], key)
        fixture.write_text("Replacementnebula refreshed text.")
        self.assertEqual(self.call("search", {"query": "uniquequasar"})["result"]["hits"], [])
        self.assertEqual(self.call("search", {"query": "replacementnebula"})["result"]["hits"][0]["document_id"], key)
        self.call("shutdown")
        self.assertEqual(self.child.wait(timeout=5), 0)

    def test_invalid_inputs_and_source_boundaries(self):
        fixture = self.root / "fixture.txt"
        fixture.write_text("safe source")
        key = self.configure()
        for offset in [-1, 100, True, 1.5]:
            self.assertEqual(self.call("read", {"document_id": key, "offset": offset})["status"], "unavailable")
        for query in ["", " ", "x" * 513, True]:
            self.assertEqual(self.call("search", {"query": query})["status"], "unavailable")
        fixture.write_bytes(b"x" * 1_048_577)
        self.assertEqual(self.call("read", {"document_id": key})["status"], "unavailable")
        fixture.write_bytes(b"\xff")
        self.assertEqual(self.call("read", {"document_id": key})["status"], "unavailable")
        fixture.unlink()
        fixture.symlink_to("/etc/hosts")
        self.assertEqual(self.call("read", {"document_id": key})["status"], "unavailable")
        self.call("shutdown")
        self.assertEqual(self.child.wait(timeout=5), 0)

    def test_embedded_nul_does_not_truncate_text_or_index(self):
        text = "Uniquequasar\0 lexical retrieval Nulnebula."
        (self.root / "fixture.txt").write_text(text)
        key = self.configure()
        self.assertEqual(self.call("read", {"document_id": key})["result"]["text"], text)
        self.assertEqual(self.call("search", {"query": "nulnebula"})["result"]["hits"],
                         [{"document_id": key, "text": text}])
        self.call("shutdown")
        self.assertEqual(self.child.wait(timeout=5), 0)

    def test_exclusive_store_owner(self):
        other = self.launch()
        try:
            self.assertEqual(other.wait(timeout=5), 2)
        finally:
            if other.poll() is None: other.kill()
            other.communicate(timeout=5)

    def test_cancel_control_stays_responsive_during_search(self):
        (self.root / "fixture.txt").write_text("Uniquequasar lexical retrieval. " * 3000)
        documents = [{"document_id": str(uuid.uuid4()), "name": "fixture.txt"} for _ in range(100)]
        self.assertEqual(self.call("configure", {"root": str(self.root), "documents": documents})["status"], "ok")
        target, cancellation = str(uuid.uuid4()), str(uuid.uuid4())
        frames = []
        for identifier, operation, payload in [(target, "search", {"query": "uniquequasar"}),
                                                (cancellation, "cancel", {"request_id": target})]:
            body = json.dumps({"protocol": 1, "id": identifier, "operation": operation,
                               "session_id": self.session, "payload": payload}).encode()
            frames.append(struct.pack(">I", len(body)) + body)
        self.child.stdin.write(b"".join(frames)); self.child.stdin.flush()
        replies = {}
        deadline = time.monotonic() + 5
        for _ in range(2):
            length = struct.unpack(">I", self.read_exact(4, deadline))[0]
            reply = json.loads(self.read_exact(length, deadline))
            replies[reply["id"]] = reply["status"]
        self.assertEqual(replies[cancellation], "ok")
        # A completed operation may win the cancellation race; neither path emits a late duplicate.
        self.assertIn(replies[target], ("ok", "cancelled"))
        self.assertEqual(self.call("hello")["status"], "ok")
        self.call("shutdown")
        self.assertEqual(self.child.wait(timeout=5), 0)

    def test_ambient_secrets_are_reported_not_used(self):
        # The native helper has no import path or credential consumer; the signed harness
        # separately checks that the real supervisor strips the environment before launch.
        child = subprocess.Popen([str(HELPER), str(self.root / "polluted-store")], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env={"OPENAI_API_KEY": "synthetic-secret-canary", "PYTHONPATH": str(self.root)})
        try:
            body = json.dumps({"protocol": 1, "id": str(uuid.uuid4()), "operation": "hello", "payload": {}}).encode()
            stdout, stderr = child.communicate(struct.pack(">I", len(body)) + body, timeout=5)
            size = struct.unpack(">I", stdout[:4])[0]
            reply = json.loads(stdout[4:4 + size])
            self.assertFalse(reply["result"]["isolated"])
            self.assertTrue(reply["result"]["secret_present"])
            self.assertNotIn(b"synthetic-secret-canary", stdout + stderr)
            self.assertEqual(child.returncode, 0)
        finally:
            if child.poll() is None: child.kill(); child.communicate(timeout=5)

    def test_duplicate_request_and_invalid_version_exit(self):
        for version in [True, 2]:
            if self.child.poll() is not None:
                self.child.communicate(timeout=5)
                self.child = self.launch()
            body = json.dumps({"protocol": version, "id": str(uuid.uuid4()), "operation": "hello", "payload": {}}).encode()
            self.child.stdin.write(struct.pack(">I", len(body)) + body)
            self.child.stdin.flush()
            self.assertEqual(self.child.wait(timeout=5), 2)
        self.child.communicate(timeout=5)
        self.child = self.launch()
        body = json.dumps({"protocol": 1, "id": str(uuid.uuid4()), "operation": "hello", "payload": {}}).encode()
        frame = struct.pack(">I", len(body)) + body
        self.child.stdin.write(frame + frame); self.child.stdin.flush()
        self.assertEqual(self.child.wait(timeout=5), 2)

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
