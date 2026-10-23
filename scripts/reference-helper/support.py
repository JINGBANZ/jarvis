"""Shared host-side fixture and framed-helper client for unittest discovery."""
import json
import os
from pathlib import Path
import select
import runpy
import struct
import subprocess
import tempfile
import time
import unittest
import uuid
import zipfile

HELPER = None
FIXTURES = runpy.run_path(str(Path(__file__).with_name("generate-fixtures.py")))
launch_owned = runpy.run_path(str(Path(__file__).resolve().parents[1] / "lib/test-command-ownership.py"))["launch_owned"]


def identifier():
    return str(uuid.uuid4())


def docx(path, body, compression=zipfile.ZIP_DEFLATED):
    with zipfile.ZipFile(path, "w", compression=compression) as archive:
        archive.writestr("_rels/.rels", '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
        archive.writestr("word/document.xml", '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' + body + '</w:body></w:document>')


class HelperTestCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.sources = self.root / "sources"
        self.sources.mkdir()
        self.app = identifier()
        self.session = identifier()
        self.start = identifier()
        self.source = identifier()
        self.generation = 0
        self.child = self.launch()
        self.addCleanup(self.close_child)
        hello = self.call("hello", timeout=30)["result"]
        self.assertTrue(hello["isolated"])
        self.assertFalse(hello["secret_present"])
        self.assertEqual(hello["engine"], "sqlite-fts5")

    def launch(self):
        return launch_owned([str(getattr(self, "executable", HELPER)), str(self.root / "store")], stdin=subprocess.PIPE,
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

    def send(self, operation, payload=None, split=False, session=None):
        request_id = identifier()
        body_payload = {"app_instance_id": self.app, **(payload or {})}
        body = json.dumps({"protocol": 1, "id": request_id, "operation": operation,
                           "session_id": session or self.session, "payload": body_payload}).encode()
        frame = struct.pack(">I", len(body)) + body
        if split:
            self.child.stdin.write(frame[:2]); self.child.stdin.flush()
            self.child.stdin.write(frame[2:])
        else:
            self.child.stdin.write(frame)
        self.child.stdin.flush()
        return request_id

    def receive(self, timeout=5):
        deadline = time.monotonic() + timeout
        length = struct.unpack(">I", self.read_exact(4, deadline))[0]
        self.assertLessEqual(length, 1_048_576)
        reply = json.loads(self.read_exact(length, deadline))
        self.assertEqual(reply["protocol"], 1)
        return reply

    def call(self, operation, payload=None, split=False, timeout=5, session=None):
        request_id = self.send(operation, payload, split, session)
        reply = self.receive(timeout)
        self.assertEqual(reply["id"], request_id)
        return reply

    def result(self, operation, payload=None, session=None, timeout=5):
        reply = self.call(operation, payload, session=session, timeout=timeout)
        self.assertEqual(reply["status"], "ok", reply)
        return reply["result"]

    def configure(self, enabled=True, sources=None, readiness_timeout=5):
        self.generation += 1
        result = self.result("configure", {"generation": self.generation, "enabled": enabled,
                             "sources": sources if sources is not None else [{"source_id": self.source, "path": str(self.sources), "is_directory": True}]})
        deadline = time.monotonic() + readiness_timeout
        while result.get("state") == "preparing" and time.monotonic() < deadline:
            time.sleep(.01)
            result = self.result("metadata", {"generation": self.generation})
        return result

    def admit(self, session=None, start=None):
        result = self.result("admit", {"generation": self.generation, "start_id": start or self.start}, session=session)
        self.assertEqual(result["state"], "ready", result)
        return result["catalog"]

    def prepare(self, text="Uniquequasar lexical retrieval.", name="fixture.txt"):
        (self.sources / name).write_text(text)
        self.assertEqual(self.configure()["state"], "ready")
        return self.admit()["entries"][0]["document_id"]

    def read(self, key, offset=0, session=None, **extra):
        return self.result("read", {"document_id": key, "offset": offset, **extra}, session=session, timeout=20)

    def restart(self):
        self.result("shutdown")
        self.assertEqual(self.child.wait(timeout=5), 0)
        self.child.communicate(timeout=5)
        self.child = self.launch()
        self.result("hello")
