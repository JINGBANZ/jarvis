"""Host-only framed contracts for the native helper; invoked by the ordinary Gate."""
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import struct
import subprocess
import time
import zipfile

from support import FIXTURES, HELPER, HelperTestCase, docx, identifier, launch_owned


class HelperContracts(HelperTestCase):
    def test_scalar_pages_nul_and_private_storage(self):
        text = "Uniquequasar\0 lexical retrieval.\n" + "😀e\u0301" * 6000
        key = self.prepare(text)
        self.result("hello", {})
        self.call("hello", split=True)
        first = self.read(key)
        self.assertEqual(first["status"], "ok")
        self.assertEqual(len(first["text"]), 16000)
        self.assertIsInstance(first["search_ready"], bool)
        second = self.read(key, first["next_offset"])
        self.assertEqual(first["text"] + second["text"], text)
        self.assertEqual(second["total_scalars"], len(text))
        self.assertEqual(second["next_offset"], len(text))
        self.assertEqual(first["revision_id"], second["revision_id"])
        for path in [self.root / "store", *(self.root / "store").rglob("*")]:
            self.assertEqual(path.stat().st_mode & 0o077, 0, str(path))
        self.result("release", {"start_id": self.start})
        self.assertEqual(self.read(key)["status"], "unknown_session")

    def test_first_read_pins_text_after_edit_delete_and_restart(self):
        text = "original revision " + "a" * 17000
        key = self.prepare(text)
        first = self.read(key)
        fixture = self.sources / "fixture.txt"
        fixture.write_text("new revision")
        self.assertEqual(self.configure()["state"], "ready")
        fixture.unlink()
        self.restart()
        self.result("reconcile", {"owned_session_ids": [self.session]})
        second = self.read(key, first["next_offset"])
        self.assertEqual(first["text"] + second["text"], text)
        self.assertEqual(first["revision_id"], second["revision_id"])

    def test_edit_before_use_and_metadata_never_pins(self):
        key = self.prepare("initial")
        self.result("list")
        (self.sources / "fixture.txt").write_text("latest before first use")
        first = self.read(key)
        self.assertEqual(first["status"], "ok")
        self.assertEqual(first["text"], "latest before first use")
        (self.sources / "fixture.txt").write_text("next session revision")
        self.configure()
        other = identifier()
        self.admit(session=other, start=identifier())
        later = self.read(key, session=other)
        self.assertEqual(later["text"], "next session revision")
        self.assertNotEqual(first["revision_id"], later["revision_id"])
        self.assertEqual(self.read(key)["text"], first["text"])

    def test_corrupt_pinned_text_is_rejected_instead_of_returned(self):
        key = self.prepare("verified original bytes")
        pinned = self.read(key)
        with sqlite3.connect(self.root / "store" / "documents.sqlite") as database:
            database.execute("UPDATE content_parts SET bytes=? WHERE revision_id=?", (b"corrupt bytes", pinned["revision_id"]))
        self.assertEqual(self.read(key)["status"], "unavailable")

    def test_new_app_instance_releases_previous_session_membership(self):
        key = self.prepare("previous app pin")
        self.assertEqual(self.read(key)["status"], "ok")
        self.restart()
        self.app = identifier()
        self.assertEqual(self.read(key)["status"], "unknown_session")
        with sqlite3.connect(self.root / "store" / "documents.sqlite") as database:
            self.assertEqual(database.execute("SELECT count(*) FROM session_documents").fetchone()[0], 0)
        self.assertEqual(self.configure()["state"], "ready")
        self.assertEqual(self.admit(session=identifier(), start=identifier())["total_count"], 1)

    def test_atomic_save_then_rename_keeps_unread_session_document(self):
        key = self.prepare("initial bytes")
        replacement = self.sources / "replacement.txt"
        replacement.write_text("updated exact source bytes")
        replacement.replace(self.sources / "fixture.txt")
        self.assertEqual(self.configure()["state"], "ready")
        (self.sources / "fixture.txt").rename(self.sources / "renamed.txt")
        self.assertEqual(self.configure()["state"], "ready")
        latest = self.admit(session=identifier(), start=identifier())["entries"]
        self.assertEqual(latest[0]["document_id"].lower(), key.lower())
        result = self.read(key)
        self.assertEqual(result["status"], "ok", result)
        self.assertEqual(result["text"], "updated exact source bytes")
        self.assertEqual(result["name"], "fixture.txt")

    def test_invalid_read_does_not_pin(self):
        key = self.prepare("short")
        self.assertEqual(self.read(key, 100)["status"], "invalid_offset")
        self.assertEqual(self.read(key, revision_id="forged")["status"], "revision_mismatch")
        (self.sources / "fixture.txt").write_text("new unpinned content")
        self.assertEqual(self.read(key)["text"], "new unpinned content")
        for offset in [-1, True, 1.5]:
            self.assertNotEqual(self.read(key, offset)["status"], "ok")

    def test_successful_empty_reads_pin_across_edits_and_restart(self):
        for name, original in [("empty.txt", ""), ("eof.md", "nonempty source")]:
            with self.subTest(name=name):
                fixture = self.sources / name
                fixture.write_text(original)
                self.configure()
                session = identifier()
                catalog = self.admit(session=session, start=identifier())
                key = next(entry["document_id"] for entry in catalog["entries"] if entry["name"] == name)
                first = self.read(key, len(original), session=session)
                self.assertEqual(first["status"], "ok", first)
                self.assertEqual(first["text"], "")
                fixture.write_text("replacement content")
                self.assertEqual(self.read(key, session=session)["text"], original)
                fixture.unlink()
                self.restart()
                self.result("reconcile", {"owned_session_ids": [session]})
                again = self.read(key, session=session)
                self.assertEqual(again["revision_id"], first["revision_id"])
                self.assertEqual(again["text"], original)

    def test_unpinned_missing_or_unreadable_source_has_no_stale_fallback(self):
        key = self.prepare("original")
        other = identifier()
        self.admit(session=other, start=identifier())
        self.assertEqual(self.read(key)["status"], "ok")
        (self.sources / "fixture.txt").unlink()
        self.assertEqual(self.read(key)["text"], "original")
        self.assertNotEqual(self.read(key, session=other)["status"], "ok")

    def test_disabled_future_configuration_keeps_unread_member_access(self):
        (self.sources / "a.txt").write_text("a")
        (self.sources / "b.txt").write_text("b")
        self.configure()
        catalog = self.admit()
        self.assertEqual(self.configure(enabled=False)["state"], "disabled")
        for entry in catalog["entries"]:
            self.assertEqual(self.read(entry["document_id"])["status"], "ok")
        omitted = self.result("admit", {"generation": self.generation, "start_id": identifier()}, session=identifier())
        self.assertEqual(omitted["state"], "disabled")

    def test_stable_identity_edits_atomic_save_and_rename(self):
        key = self.prepare("first")
        fixture = self.sources / "fixture.txt"
        replacement = self.sources / "replacement.tmp"
        replacement.write_text("atomic save")
        replacement.replace(fixture)
        self.configure()
        catalog = self.admit(session=identifier(), start=identifier())
        self.assertEqual(catalog["entries"][0]["document_id"], key)
        fixture.rename(self.sources / "renamed.txt")
        self.configure()
        catalog = self.admit(session=identifier(), start=identifier())
        self.assertEqual(catalog["entries"][0]["document_id"], key)
        self.assertEqual(catalog["entries"][0]["name"], "renamed.txt")

    def test_observed_delete_recreate_has_new_identity_and_cannot_rebind_old_session(self):
        key = self.prepare("old document")
        fixture = self.sources / "fixture.txt"
        fixture.unlink()
        self.assertEqual(self.configure()["total_count"], 0)
        fixture.write_text("unrelated replacement")
        self.configure()
        other = identifier()
        catalog = self.admit(session=other, start=identifier())
        new_key = catalog["entries"][0]["document_id"]
        self.assertNotEqual(new_key, key)
        self.assertNotEqual(self.read(key)["status"], "ok")
        self.assertEqual(self.read(new_key, session=other)["text"], "unrelated replacement")

    def test_directory_named_like_document_is_traversed(self):
        nested = self.sources / "archive.md"
        nested.mkdir()
        (nested / "real.txt").write_text("inside directory")
        self.assertEqual(self.configure()["state"], "ready")
        catalog = self.admit()
        self.assertEqual(catalog["total_count"], 1)
        self.assertEqual(self.read(catalog["entries"][0]["document_id"])["text"], "inside directory")

    def test_observed_absence_does_not_revive_same_inode_at_old_or_new_path(self):
        for returned_name in ["fixture.txt", "returned.txt"]:
            with self.subTest(name=returned_name):
                key = self.prepare("before absence")
                fixture = self.sources / "fixture.txt"
                parked = self.root / "parked.txt"
                fixture.rename(parked)
                self.assertEqual(self.configure()["total_count"], 0)
                parked.rename(self.sources / returned_name)
                self.configure()
                session = identifier()
                entry = self.admit(session=session, start=identifier())["entries"][0]
                self.assertNotEqual(entry["document_id"], key)
                self.assertNotEqual(self.read(key)["status"], "ok")
                self.assertEqual(self.read(entry["document_id"], session=session)["text"], "before absence")
                (self.sources / returned_name).unlink()
                self.configure()
                self.session, self.start = identifier(), identifier()

    def test_directory_skips_unsupported_and_ineligible_entries(self):
        (self.sources / "good.txt").write_text("eligible text")
        for name in ["sheet.xlsx", "photo.png", "data.csv", "config.json", "notes.markdown"]:
            (self.sources / name).write_bytes(b"unsupported fixture")
        (self.sources / "escape.txt").symlink_to(self.root / "outside.txt")
        (self.root / "outside.txt").write_text("outside root")
        (self.sources / "broken.md").symlink_to(self.root / "missing")
        os.mkfifo(self.sources / "pipe.txt", 0o600)
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(str(self.sources / "socket.txt"))
            metadata = self.configure()
            self.assertEqual(metadata["state"], "ready", metadata)
            catalog = self.admit()
            self.assertEqual([entry["name"] for entry in catalog["entries"]], ["good.txt"])
        unsupported = self.sources / "sheet.xlsx"
        failed = self.configure(sources=[{"source_id": identifier(), "path": str(unsupported), "is_directory": False}])
        self.assertEqual(failed["state"], "failed")
        self.assertEqual(failed["error"], "unsupported_format")

    def test_selected_file_replaced_by_directory_does_not_expand_access(self):
        selected = self.sources / "selected.md"
        selected.write_text("original selected file")
        sources = [{"source_id": self.source, "path": str(selected), "is_directory": False}]
        self.assertEqual(self.configure(sources=sources)["state"], "ready")
        key = self.admit()["entries"][0]["document_id"]
        first = self.read(key)
        selected.unlink()
        selected.mkdir()
        (selected / "unselected.txt").write_text("must not become a reference")
        failed = self.configure(sources=sources)
        self.assertEqual(failed["state"], "failed", failed)
        self.assertEqual(failed["error"], "invalid_source")
        self.assertEqual(self.read(key)["text"], first["text"])

    def test_selected_file_symlink_retargeted_to_directory_does_not_expand_access(self):
        target = self.sources / "target.md"
        target.write_text("original symlink target")
        selected = self.root / "selected.md"
        selected.symlink_to(target)
        sources = [{"source_id": self.source, "path": str(selected), "is_directory": False}]
        self.assertEqual(self.configure(sources=sources)["state"], "ready")
        self.assertEqual(self.admit()["total_count"], 1)
        selected.unlink()
        selected.symlink_to(self.sources, target_is_directory=True)
        failed = self.configure(sources=sources)
        self.assertEqual(failed["state"], "failed", failed)
        self.assertEqual(failed["error"], "invalid_source")

    def test_selected_directory_replaced_by_file_is_rejected(self):
        selected = self.sources / "selected.md"
        selected.mkdir()
        sources = [{"source_id": self.source, "path": str(selected), "is_directory": True}]
        self.assertEqual(self.configure(sources=sources)["state"], "ready")
        selected.rmdir()
        selected.write_text("replacement file")
        failed = self.configure(sources=sources)
        self.assertEqual(failed["state"], "failed", failed)
        self.assertEqual(failed["error"], "invalid_source")

    def test_source_kind_is_required_and_must_be_boolean(self):
        for kind in [None, "false"]:
            source = {"source_id": self.source, "path": str(self.sources)}
            if kind is not None:
                source["is_directory"] = kind
            result = self.result("configure", {"generation": 1, "enabled": True, "sources": [source]})
            self.assertEqual(result["status"], "unavailable", result)

    def test_discovery_bounds_sources_and_total_traversal_work(self):
        many = [{"source_id": identifier(), "path": str(self.sources), "is_directory": True} for _ in range(129)]
        reply = self.result("configure", {"generation": 1, "enabled": True, "sources": many})
        self.assertEqual(reply["status"], "resource_limit")
        # Repeated roots must share one work budget even when all entries are unsupported.
        for index in range(1024): (self.sources / f"{index}.bin").touch()
        overlapping = [{"source_id": identifier(), "path": str(self.sources), "is_directory": True} for _ in range(98)]
        failed = self.configure(sources=overlapping, readiness_timeout=30)
        self.assertEqual(failed["state"], "failed", failed)
        self.assertEqual(failed["error"], "resource_limit")
        self.assertEqual(self.configure()["state"], "ready")

    def test_concurrent_first_search_indexes_each_revision_once(self):
        key = self.prepare("Uniquequasar " + "x" * 2_000_000)
        self.assertEqual(self.read(key)["status"], "ok")
        deadline = time.monotonic() + 15
        while True:
            result = self.result("search", {"query": "uniquequasar"})
            if result["complete"]:
                break
            self.assertLess(time.monotonic(), deadline, result)
            time.sleep(.02)
        first = self.send("search", {"query": "uniquequasar"})
        second = self.send("search", {"query": "uniquequasar"})
        replies = {reply["id"]: reply for reply in [self.receive(), self.receive()]}
        for request in [first, second]:
            self.assertEqual(replies[request]["result"]["status"], "ok")
            self.assertEqual(len(replies[request]["result"]["hits"]), 1)
        with sqlite3.connect(self.root / "store/documents.sqlite") as database:
            self.assertEqual(database.execute("SELECT count(*) FROM passages").fetchone()[0], database.execute("SELECT count(*) FROM chunks").fetchone()[0])
            self.assertEqual(database.execute("SELECT count(*) FROM (SELECT revision_id,generation,ordinal,count(*) c FROM passages GROUP BY 1,2,3 HAVING c>1)").fetchone()[0], 0)

    def test_unreadable_unpinned_file_does_not_serve_cached_text(self):
        key = self.prepare("source permissions")
        first = self.read(key)
        other = identifier()
        self.admit(session=other, start=identifier())
        fixture = self.sources / "fixture.txt"
        fixture.chmod(0)
        try:
            self.assertNotEqual(self.read(key, session=other)["status"], "ok")
            self.assertEqual(self.read(key)["text"], first["text"])
        finally: fixture.chmod(0o600)

    def test_overlapping_roots_deduplicate_but_duplicate_names_remain_distinct(self):
        nested = self.sources / "nested"
        nested.mkdir()
        (self.sources / "same.txt").write_text("first")
        (nested / "same.txt").write_text("second")
        self.configure(sources=[{"source_id": self.source, "path": str(self.sources), "is_directory": True},
                                {"source_id": identifier(), "path": str(nested), "is_directory": True}])
        catalog = self.admit()
        self.assertEqual(catalog["total_count"], 2)
        self.assertEqual(len({entry["document_id"] for entry in catalog["entries"]}), 2)

    def test_bounded_catalog_full_paginated_listing_and_frozen_membership(self):
        for i in range(240):
            (self.sources / (str(i).zfill(3) + "-" + "😀" * 40 + ".txt")).write_text("fixture")
        self.configure()
        catalog = self.admit()
        self.assertEqual(catalog["total_count"], 240)
        self.assertLessEqual(len(catalog["entries"]), 200)
        self.assertLessEqual(len(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")).encode()), 16384)
        self.assertEqual(catalog["omitted_count"], 240 - len(catalog["entries"]))
        (self.sources / "later.txt").write_text("not admitted")
        self.configure()
        entries, cursor = [], None
        while True:
            result = self.result("list", {} if cursor is None else {"cursor": cursor})
            entries.extend(result["entries"])
            cursor = result.get("next_cursor")
            if cursor is None: break
        self.assertEqual(len(entries), 240)
        self.assertEqual(len({entry["document_id"] for entry in entries}), 240)
        self.assertNotIn("later.txt", [entry["name"] for entry in entries])

    def test_unchanged_revision_reused_after_restart(self):
        fixture = self.sources / "cached.docx"
        docx(fixture, "<w:p><w:r><w:t>persisted text</w:t></w:r></w:p>")
        self.configure()
        key = self.admit()["entries"][0]["document_id"]
        first = self.read(key)
        self.result("release", {"start_id": self.start})
        self.executable = self.root / "isolated-helper"
        shutil.copy2(HELPER, self.executable)
        self.restart()
        # The running helper remains mapped; any new converter launch at its path must fail.
        self.executable.rename(self.root / "unavailable-worker")
        self.configure()
        self.session, self.start = identifier(), identifier()
        self.admit()
        self.assertEqual(self.read(key)["revision_id"], first["revision_id"])
        with sqlite3.connect(self.root / "store/documents.sqlite") as database:
            self.assertEqual(database.execute("SELECT count(*) FROM revisions").fetchone()[0], 1)
        docx(fixture, "<w:p><w:r><w:t>changed source requires conversion</w:t></w:r></w:p>")
        later = identifier()
        self.admit(session=later, start=identifier())
        self.assertNotEqual(self.read(key, session=later)["status"], "ok")

    def test_abandon_and_release_tombstone_late_admission(self):
        (self.sources / "fixture.txt").write_text("safe")
        self.configure()
        self.result("abandon", {"start_id": self.start})
        result = self.result("admit", {"generation": self.generation, "start_id": self.start})
        self.assertNotEqual(result["state"], "ready")
        later, start = identifier(), identifier()
        self.result("release", {"start_id": start}, session=later)
        result = self.result("admit", {"generation": self.generation, "start_id": start}, session=later)
        self.assertNotEqual(result["state"], "ready")

    def test_unknown_app_and_stale_generation_cannot_access_or_admit(self):
        key = self.prepare()
        self.assertNotEqual(self.result("read", {"app_instance_id": identifier(), "document_id": key})["status"], "ok")
        result = self.result("admit", {"generation": self.generation - 1, "start_id": identifier()}, session=identifier())
        self.assertNotEqual(result["state"], "ready")

    def test_pdf_pages_keep_text_order_and_image_only_is_unavailable(self):
        fixture = self.sources / "pages.pdf"
        FIXTURES["write_pdf"](fixture, [["Payment Q7", "ORCHID-439: 61 days"], ["Second page", "QUARTZ-982: reviewed"]])
        self.configure()
        key = self.admit()["entries"][0]["document_id"]
        result = self.read(key)
        self.assertEqual(result["status"], "ok", result)
        self.assertLess(result["text"].index("ORCHID-439"), result["text"].index("QUARTZ-982"))
        other = identifier()
        self.admit(session=other, start=identifier())
        FIXTURES["write_pdf"](fixture, [[]])
        self.assertNotEqual(self.read(key, session=other)["status"], "ok")
        self.assertIn("ORCHID-439", self.read(key)["text"])

    def test_docx_preserves_interleaved_tables_and_reuses_conversion(self):
        body = '<w:p><w:r><w:t>Before 😀</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell A</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Cell B</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p><w:r><w:t>After é</w:t></w:r></w:p>'
        docx(self.sources / "table.docx", body)
        self.configure()
        key = self.admit()["entries"][0]["document_id"]
        result = self.read(key)
        self.assertEqual(result["status"], "ok", result)
        text = result["text"]
        self.assertLess(text.index("Before"), text.index("Cell A"))
        self.assertLess(text.index("Cell A"), text.index("Cell B"))
        self.assertLess(text.index("Cell B"), text.index("After"))
        self.assertIn("\t", text)
        self.restart()
        self.result("reconcile", {"owned_session_ids": [self.session]})
        self.assertEqual(self.read(key)["revision_id"], result["revision_id"])

    def test_docx_xml_entities_and_expansion_are_bounded(self):
        fixture = self.sources / "unsafe.docx"
        relationships = '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
        with zipfile.ZipFile(fixture, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("_rels/.rels", relationships)
            archive.writestr("word/document.xml", '<!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>&xxe;</w:t></w:r></w:p></w:body></w:document>')
        self.configure()
        key = self.admit()["entries"][0]["document_id"]
        self.assertEqual(self.read(key)["status"], "invalid_document")
        # Very small compressed input must not permit unbounded expanded allocations.
        with zipfile.ZipFile(fixture, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("_rels/.rels", relationships)
            with archive.open("word/document.xml", "w") as output:
                for _ in range(101): output.write(b"x" * 1_048_576)
        self.assertEqual(self.read(key)["status"], "limit_exceeded")
        self.assertEqual(self.result("hello")["engine"], "sqlite-fts5")

    def test_docx_tab_stop_properties_do_not_emit_text(self):
        body = '<w:p><w:pPr><w:tabs><w:tab w:val="left" w:pos="720"/><w:tab w:val="right" w:pos="1440"/></w:tabs></w:pPr><w:r><w:t>Before</w:t><w:tab/><w:t>After</w:t></w:r></w:p>'
        docx(self.sources / "tabs.docx", body)
        self.configure()
        key = self.admit()["entries"][0]["document_id"]
        self.assertEqual(self.read(key)["text"], "Before\tAfter\n")

    def test_source_boundaries_fifo_symlink_invalid_text_and_limits(self):
        key = self.prepare()
        fixture = self.sources / "fixture.txt"
        fixture.unlink()
        fixture.symlink_to("/etc/hosts")
        self.assertNotEqual(self.read(key)["status"], "ok")
        fixture.unlink()
        os.mkfifo(fixture, 0o600)
        self.assertNotEqual(self.read(key)["status"], "ok")
        fixture.unlink()
        fixture.write_bytes(b"\xff")
        self.assertNotEqual(self.read(key)["status"], "ok")
        with fixture.open("wb") as output: output.truncate(25 * 1_048_576 + 1)
        self.assertNotEqual(self.read(key)["status"], "ok")
        self.assertEqual(self.call("shutdown")["status"], "ok")
        self.assertEqual(self.child.wait(timeout=5), 0)

    def test_exclusive_store_owner(self):
        other = self.launch()
        try:
            self.assertEqual(other.wait(timeout=5), 2)
        finally:
            if other.poll() is None: other.kill()
            other.communicate(timeout=5)

    def test_cancel_control_stays_responsive_during_read(self):
        key = self.prepare("Uniquequasar lexical retrieval. " * 3000)
        target = self.send("read", {"document_id": key})
        cancellation = self.send("cancel", {"request_id": target})
        replies = {reply["id"]: reply for reply in [self.receive(), self.receive()]}
        self.assertEqual(replies[cancellation]["status"], "ok")
        self.assertIn(replies[target]["status"], ("ok", "cancelled"))
        self.assertEqual(self.call("hello")["status"], "ok")

    def test_ambient_secrets_reported_without_echo(self):
        child = launch_owned([str(HELPER), str(self.root / "polluted-store")], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env={"OPENAI_API_KEY": "synthetic-secret-canary", "PYTHONPATH": str(self.root)})
        try:
            body = json.dumps({"protocol": 1, "id": identifier(), "operation": "hello", "payload": {}}).encode()
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
            body = json.dumps({"protocol": version, "id": identifier(), "operation": "hello", "payload": {}}).encode()
            self.child.stdin.write(struct.pack(">I", len(body)) + body); self.child.stdin.flush()
            self.assertEqual(self.child.wait(timeout=5), 2)
        self.child.communicate(timeout=5)
        self.child = self.launch()
        body = json.dumps({"protocol": 1, "id": identifier(), "operation": "hello", "payload": {}}).encode()
        frame = struct.pack(">I", len(body)) + body
        self.child.stdin.write(frame + frame); self.child.stdin.flush()
        self.assertEqual(self.child.wait(timeout=5), 2)

    def test_oversized_frame_exits(self):
        self.child.stdin.write(struct.pack(">I", 1_048_577)); self.child.stdin.flush()
        self.assertEqual(self.child.wait(timeout=15), 2)

    def test_truncated_frame_exits(self):
        self.child.stdin.write(b"\0\0"); self.child.stdin.close()
        self.assertEqual(self.child.wait(timeout=15), 2)
        self.child.stdin = None
