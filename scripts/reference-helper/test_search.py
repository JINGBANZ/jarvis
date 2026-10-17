"""Host-only ranked retrieval contracts; real helper/SQLite and public framed protocol."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import sys
import time
import unittest
import unicodedata
import uuid

spec = importlib.util.spec_from_file_location("reference_contracts", Path(__file__).with_name("test_helper.py"))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


class SearchContracts(unittest.TestCase):
    setUp = base.HelperContracts.setUp
    launch = base.HelperContracts.launch
    close_child = base.HelperContracts.close_child
    read_exact = base.HelperContracts.read_exact
    send = base.HelperContracts.send
    receive = base.HelperContracts.receive
    call = base.HelperContracts.call
    result = base.HelperContracts.result
    configure = base.HelperContracts.configure
    admit = base.HelperContracts.admit
    prepare = base.HelperContracts.prepare
    read = base.HelperContracts.read
    restart = base.HelperContracts.restart

    @property
    def database(self):
        return self.root / "store/documents.sqlite"

    def gate(self, name):
        path = self.root / "store" / name
        path.write_text("hold")
        return path

    def arrived(self, name, timeout=10):
        deadline = time.monotonic() + timeout
        while not (self.root / "store" / (name + "-arrived")).exists():
            self.assertLess(time.monotonic(), deadline, name)
            time.sleep(.01)

    def search(self, query, document_ids=None):
        payload = {"query": query}
        if document_ids is not None:
            payload["document_ids"] = document_ids
        return self.result("search", payload, timeout=4)

    def ready(self, query="quasar", count=None, timeout=15):
        deadline = time.monotonic() + timeout
        while True:
            result = self.search(query)
            if result.get("complete") and (count is None or result["coverage"]["searched_documents"] == count):
                return result
            self.assertLess(time.monotonic(), deadline, result)
            time.sleep(.02)

    def pins(self):
        with sqlite3.connect(self.database) as db:
            return dict(db.execute("SELECT document_id,pin FROM session_documents WHERE session_id=?", (self.session,)))

    def test_full_tail_search_first_pin_and_original_offsets(self):
        text = "# Overview\r\n\r\n" + ("😀e\u0301 background words.\r\n\r\n" * 1800) + "# Payments\r\n\r\nuniquequasar 支付失败 账单-42 evidence.\r\n"
        key = self.prepare(text, "Payment.md")
        # Readiness probes cannot pin documents unrelated to their queries.
        self.ready("nonexistenttoken", count=1)
        self.assertIsNone(self.pins()[key])
        result = self.search("uniquequasar")
        self.assertTrue(result["complete"], result)
        hit = result["hits"][0]
        self.assertEqual(hit["document_id"], key)
        self.assertGreater(hit["offset"], 16_000)
        self.assertIn("uniquequasar", hit["text"])
        self.assertEqual(hit["section"], "# Payments")
        self.assertEqual(text[hit["offset"]:hit["next_offset"]], hit["text"])
        self.assertLessEqual(len(hit["text"]), 2000)
        self.assertEqual(self.pins()[key], hit["revision_id"])
        (self.sources / "Payment.md").write_text("replacement")
        self.restart()
        page = self.read(key, hit["offset"], revision_id=hit["revision_id"])
        self.assertTrue(page["text"].startswith(hit["text"]))
        self.assertEqual(self.search("uniquequasar")["hits"][0]["revision_id"], hit["revision_id"])

    def test_identifiers_chinese_mixed_names_and_negatives(self):
        fixtures = {"cpp.md": "C++ templates and ownership.", "csharp.md": "C# managed types.",
                    "hyphen.md": "账单-42 支付失败排查与退款流程。", "underscore.md": "账单_42 支付成功处理。",
                    "spaces.md": "账单 42 has spaces.", "Payment.md": "Provider-specific retry backoff."}
        for name, text in fixtures.items():
            (self.sources / name).write_text(text)
        self.configure(); catalog = self.admit()
        names = {entry["document_id"]: entry["name"] for entry in catalog["entries"]}
        self.ready("absenttoken", count=len(fixtures))
        for query, expected in [("C++", {"cpp.md"}), ("C#", {"csharp.md"}), ("账单-42", {"hyphen.md"}),
                                ("账单_42", {"underscore.md"}), ("失败", {"hyphen.md"}), ("Payment.md", {"Payment.md"})]:
            result = self.search(query)
            self.assertEqual({names[hit["document_id"]] for hit in result["hits"]}, expected, (query, result))
        for query in ["不存在的天文词", "C++++", "账单-420", '" OR * NOT (']:
            self.assertEqual(self.search(query)["hits"], [], query)
        result = self.search("How does retry backoff work?")
        self.assertEqual(names[result["hits"][0]["document_id"]], "Payment.md")

    def test_empty_foreign_subset_and_eligibility_before_top_k(self):
        for i in range(7):
            (self.sources / f"{i}.txt").write_text(("quasar " * (20-i)) + f"document {i}")
        self.configure(); catalog = self.admit()
        self.ready("nomatch", count=7)
        entries = {entry["name"]: entry["document_id"] for entry in catalog["entries"]}
        allowed = entries["6.txt"]
        result = self.search("quasar", [allowed])
        self.assertEqual([hit["document_id"] for hit in result["hits"]], [allowed])
        self.assertEqual(result["coverage"]["eligible_documents"], 1)
        self.assertEqual(self.search("quasar", [str(uuid.uuid4())])["hits"], [])
        self.assertEqual(self.search("quasar", [])["hits"], [])
        result = self.search("quasar")
        self.assertTrue(result["complete"])
        self.assertTrue(result["truncated"])
        self.assertEqual(len(result["hits"]), 3)

    def test_sentence_punctuation_does_not_select_false_identifiers(self):
        (self.sources / "Retry.md").write_text("Provider retry backoff guidance docs long word .NET .env")
        (self.sources / "punctuation.txt").write_text(". / - _ + # ...")
        self.configure(); self.admit(); self.ready("absenttoken", count=2)
        for query in ["How does retry backoff work.", "How does retry backoff work...", "retry / backoff .", "docs/", "long-", "word_", ".NET", ".env"]:
            result = self.search(query)
            self.assertEqual([hit["name"] for hit in result["hits"]], ["Retry.md"], (query, result))
        for query in [".", "...", "/", "-", "_", "+", "#"]:
            self.assertEqual(self.search(query)["hits"], [], query)

    def test_exact_identifier_excerpt_does_not_anchor_on_loose_component(self):
        fixtures = {query: loose + " " + "unrelated " * 320 + query + " actual evidence"
                    for loose, query in [("C", "C++"), ("-42", "账单-42"), ("_42", "账单_42")]}
        for index, text in enumerate(fixtures.values()): (self.sources / f"{index}.txt").write_text(text)
        self.configure(); self.admit(); self.ready("absenttoken", count=3)
        for query, text in fixtures.items():
            result = self.search(query)
            self.assertEqual(len(result["hits"]), 1, result)
            hit = result["hits"][0]
            self.assertIn(query, hit["text"])
            self.assertEqual(text[hit["offset"]:hit["next_offset"]], hit["text"])

    def test_excerpt_ending_inside_grapheme_uses_scalar_prefix(self):
        originals = {}
        for index, boundary in enumerate(["e\u0301", "👩\u200d🚀", "🇺🇸"]):
            query = f"grapheme{index}"
            text = query + " " + "x" * (1999 - len(query) - 1) + boundary + " trailing text"
            originals[query] = text
            (self.sources / f"{index}.txt").write_text(text)
        self.configure(); self.admit(); self.ready("absenttoken", count=3)
        for query, text in originals.items():
            result = self.search(query)
            self.assertEqual(len(result["hits"]), 1, result)
            hit = result["hits"][0]
            self.assertEqual(hit["next_offset"], 2000)
            self.assertEqual(hit["text"], text[:2000])
            self.assertTrue(self.read(hit["document_id"], hit["offset"])["text"].startswith(hit["text"]))

    def test_unicode_exact_names_and_duplicate_fts_suppression(self):
        (self.sources / "Überblick.md").write_text("filename-only evidence")
        (self.sources / "Straße.md").write_text("case folding evidence")
        for folder in ["first", "second"]:
            location = self.sources / folder
            location.mkdir()
            (location / "Übersicht.md").write_text("Übersicht.md repeated " * 300)
        self.configure(); self.admit(); self.ready("absenttoken", count=4)
        for query, expected in [("überblick.md", "Überblick.md"), ("u\u0308berblick.md", "Überblick.md"), ("STRASSE.md", "Straße.md")]:
            self.assertEqual([unicodedata.normalize("NFC", hit["name"]) for hit in self.search(query)["hits"]], [expected])
            self.assertEqual([unicodedata.normalize("NFC", entry["name"]) for entry in self.result("list", {"query": query})["entries"]], [expected])
        result = self.search("übersicht.md")
        self.assertEqual(len(result["hits"]), 2, result)
        self.assertEqual(len({hit["document_id"] for hit in result["hits"]}), 2)
        self.assertFalse(result["truncated"], result)

    def test_removed_root_unpinned_markdown_keeps_frozen_format(self):
        gate = self.gate("index-before-publish")
        self.prepare("blocked first index")
        self.arrived("index-before-publish")
        text = "# Notes\n\n```swift\n# Not a section\nquasar code\n```\n\n| key | value |\n| --- | --- |\n| needle | table |\n\n# Final\nquasar final\n"
        (self.sources / "Notes.md").write_text(text)
        self.configure()
        self.session = str(uuid.uuid4()); self.start = str(uuid.uuid4())
        catalog = self.admit()
        key = next(entry["document_id"] for entry in catalog["entries"] if entry["name"] == "Notes.md")
        deadline = time.monotonic() + 5
        while True:
            with sqlite3.connect(self.database) as db:
                revision = db.execute("SELECT current_revision FROM documents WHERE id=?", (key,)).fetchone()[0]
            if revision: break
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.01)
        self.assertIsNone(self.pins()[key])
        self.configure(sources=[])
        gate.unlink()
        self.ready("absenttoken", count=2)
        with sqlite3.connect(self.database) as db:
            passages = db.execute("SELECT section,text FROM passages WHERE revision_id=? ORDER BY ordinal", (revision,)).fetchall()
        self.assertEqual([section for section, _ in passages], ["# Notes", "# Final"])
        self.assertTrue(any("```swift\n# Not a section\nquasar code\n```" in passage for _, passage in passages))
        self.assertIn("| needle | table |", passages[0][1])

    def test_index_respects_reservations_acquired_after_index_start(self):
        index_gate = self.gate("index-after-batch")
        key = self.prepare("quasar " + "x " * 20_000)
        self.arrived("index-after-batch")
        deadline = time.monotonic() + 5
        while self.result("diagnostics")["reserved_bytes"]:
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.01)
        with sqlite3.connect(self.database) as db:
            before = db.execute("SELECT count(*) FROM passages").fetchone()[0]
            db.execute("UPDATE session_documents SET pin=(SELECT current_revision FROM documents WHERE id=?) WHERE session_id=? AND document_id=?", (key, self.session, key))
        old_session = self.session
        # Real allocated padding leaves less than one index batch after two 450MiB conversion
        # reservations. A sparse file would not exercise the allocated-size contract.
        target = 1024 * 1024 * 1024 - 2 * 450 * 1024 * 1024 - 512 * 1024
        padding = target - self.result("diagnostics")["disk_bytes"]
        with (self.root / "store" / "allocated-padding").open("wb") as output:
            block = bytes(1024 * 1024)
            while padding:
                size = min(padding, len(block)); output.write(block[:size]); padding -= size
        preparation_gate = self.gate("preparation-after-reserve")
        new_sources = self.root / "new-sources"; new_sources.mkdir()
        for name in ["first.txt", "second.txt"]: (new_sources / name).write_text("new reference")
        self.configure(sources=[{"source_id": str(uuid.uuid4()), "path": str(new_sources)}])
        self.session = str(uuid.uuid4()); self.start = str(uuid.uuid4())
        catalog = self.admit()
        self.arrived("preparation-after-reserve")
        requests = {self.send("read", {"document_id": entry["document_id"], "offset": 0}) for entry in catalog["entries"]}
        for _ in requests:
            reply = self.receive(timeout=4)
            self.assertIn(reply["id"], requests)
            self.assertEqual(reply["result"]["status"], "preparing", reply)
        diagnostics = self.result("diagnostics")
        self.assertEqual(diagnostics["reserved_bytes"], 900 * 1024 * 1024)
        index_gate.unlink()
        deadline = time.monotonic() + 5
        while True:
            with sqlite3.connect(self.database) as db:
                state = db.execute("SELECT state FROM search_state WHERE revision_id=(SELECT current_revision FROM documents WHERE id=?)", (key,)).fetchone()[0]
                after = db.execute("SELECT count(*) FROM passages").fetchone()[0]
            if state != "preparing": break
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.01)
        self.assertEqual(state, "cache_full")
        self.assertEqual(after, before)
        diagnostics = self.result("diagnostics")
        self.assertLessEqual(diagnostics["disk_bytes"] + diagnostics["reserved_bytes"], 1024 * 1024 * 1024)
        # Content remains readable even though indexing cannot spend the reserved capacity.
        page = self.read(key, session=old_session)
        self.assertEqual(page["status"], "ok")
        self.assertTrue(page["text"].startswith("quasar"))
        preparation_gate.unlink()

    def test_duplicate_basenames_keep_distinct_frozen_ids(self):
        for folder in ["first", "second"]:
            location = self.sources / folder
            location.mkdir()
            (location / "Payment.md").write_text("separate evidence " + folder)
        self.configure(); catalog = self.admit()
        self.ready("absenttoken", count=2)
        result = self.search("Payment.md")
        self.assertTrue(result["complete"], result)
        self.assertEqual({hit["document_id"] for hit in result["hits"]},
                         {entry["document_id"] for entry in catalog["entries"]})
        self.assertEqual(len({hit["name"] for hit in result["hits"]}), 2)

    def test_admission_does_not_wait_for_blocked_index(self):
        gate = self.gate("index-before-publish")
        key = self.prepare("quasar authoritative text")
        self.arrived("index-before-publish")
        self.session = str(uuid.uuid4())
        started = time.monotonic()
        catalog = self.admit()
        self.assertLess(time.monotonic() - started, 1)
        self.assertEqual(catalog["entries"][0]["document_id"], key)
        self.assertFalse(self.search("quasar")["complete"])
        gate.unlink()
        self.assertTrue(self.ready("quasar", count=1)["hits"])

    def test_partial_publication_does_not_block_read_or_catalog_and_crash_rebuild(self):
        gate = self.gate("index-after-batch")
        key = self.prepare("# Header\n\n" + "quasar body\n\n" * 2000, "large.md")
        self.arrived("index-after-batch")
        started = time.monotonic()
        page = self.read(key)
        self.assertEqual(page["status"], "ok")
        self.assertFalse(page["search_ready"])
        self.assertEqual(self.result("list")["total_count"], 1)
        self.assertLess(time.monotonic() - started, 1)
        partial = self.search("quasar")
        self.assertEqual(partial["hits"], [])
        self.assertFalse(partial["complete"])
        self.assertEqual(partial["coverage"]["omissions"], {"preparing": 1})
        self.child.kill(); self.child.communicate(timeout=5)
        gate.unlink()
        self.child = self.launch(); self.result("hello")
        self.assertEqual(self.read(key)["revision_id"], page["revision_id"])
        result = self.ready("quasar", count=1)
        self.assertTrue(result["hits"])
        self.assertTrue(self.read(key)["search_ready"])
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute("SELECT count(DISTINCT generation) FROM passages").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT count(*) FROM chunks").fetchone()[0], db.execute("SELECT count(*) FROM passages").fetchone()[0])

    def test_changed_unpinned_candidate_is_removed_and_lower_hit_survives(self):
        for i in range(5):
            (self.sources / f"{i}.txt").write_text("quasar " * (10-i))
        self.configure(); catalog = self.admit(); self.ready("absenttoken", count=5)
        names = {e["document_id"]: e["name"] for e in catalog["entries"]}
        # Delete four highest-ranked candidates; checking only the original top-K would hide the fifth.
        for i in range(4):
            (self.sources / f"{i}.txt").unlink()
        result = self.search("quasar")
        self.assertEqual([names[h["document_id"]] for h in result["hits"]], ["4.txt"])
        self.assertFalse(result["complete"])
        self.assertEqual(result["coverage"]["searched_documents"], 1)
        self.assertEqual(sum(result["coverage"]["omissions"].values()), 4)
        for document, pin in self.pins().items():
            if names[document] != "4.txt":
                self.assertIsNone(pin)

    def test_pin_changed_before_validation_recomputes_from_new_pin(self):
        for name in ["first.txt", "second.txt"]:
            (self.sources / name).write_text("quasar original " + name)
        self.configure(); catalog = self.admit(); self.ready("absenttoken", count=2)
        second = next(entry["document_id"] for entry in catalog["entries"] if entry["name"] == "second.txt")
        gate = self.gate("search-before-validation")
        request = self.send("search", {"query": "quasar"})
        self.arrived("search-before-validation")
        (self.sources / "second.txt").write_text("quasar replacement second")
        replacement = self.read(second)
        deadline = time.monotonic() + 1
        while not self.read(second)["search_ready"]:
            self.assertLess(time.monotonic(), deadline)
        gate.unlink()
        result = self.receive(timeout=4)
        self.assertEqual(result["id"], request)
        self.assertTrue(result["result"]["complete"], result)
        hit = next(hit for hit in result["result"]["hits"] if hit["document_id"] == second)
        self.assertEqual(hit["revision_id"], replacement["revision_id"])
        self.assertEqual(hit["text"], "quasar replacement second")

    def test_whole_result_pin_conflict_rolls_back_new_first_pin(self):
        for name in ["A.txt", "B.txt"]:
            (self.sources / name).write_text("quasar common evidence")
        self.configure(); catalog = self.admit(); self.ready("absenttoken", count=2)
        # Ranking ties use document ID. Force a conflict on the second candidate, after A's tentative UPDATE.
        first, second = sorted(e["document_id"] for e in catalog["entries"])
        names = {e["document_id"]: e["name"] for e in catalog["entries"]}
        before = self.gate("search-before-pin")
        after = self.gate("search-after-conflict")
        request = self.send("search", {"query": "quasar"})
        self.arrived("search-before-pin")
        (self.sources / names[second]).write_text("different revision with no old query")
        competing = self.read(second)
        self.assertEqual(competing["status"], "ok")
        before.unlink(); self.arrived("search-after-conflict")
        pins = self.pins()
        self.assertIsNone(pins[first], "first provisional pin must roll back when second conflicts")
        self.assertEqual(pins[second], competing["revision_id"])
        # Displace A before recomputation; it must remain unpinned after discarded evidence.
        (self.sources / names[first]).unlink()
        after.unlink()
        result = self.receive(timeout=4)
        self.assertEqual(result["id"], request)
        self.assertEqual(result["result"]["hits"], [])
        self.assertIsNone(self.pins()[first])

    def test_stale_index_writer_cannot_publish_or_delete_new_generation(self):
        gate = self.gate("index-before-publish")
        key = self.prepare("quasar original")
        self.arrived("index-before-publish")
        with sqlite3.connect(self.database) as db:
            revision = db.execute("SELECT current_revision FROM documents WHERE id=?", (key,)).fetchone()[0]
            db.execute("UPDATE search_state SET generation='new-generation',state='ready' WHERE revision_id=?", (revision,))
            db.execute("UPDATE revisions SET search_ready=1 WHERE id=?", (revision,))
        gate.unlink()
        time.sleep(.1)
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute("SELECT generation,state FROM search_state WHERE revision_id=?", (revision,)).fetchone(), ("new-generation", "ready"))
        # Delayed stale work must not affect authoritative reads or pins even if its result is rejected.
        self.assertEqual(self.read(key)["text"], "quasar original")


    def test_derived_repair_preserves_text_pins_and_removes_obsolete_tail(self):
        key = self.prepare("quasar " + "background words\n\n" * 1000)
        self.ready("absenttoken", count=1)
        first = self.read(key)
        with sqlite3.connect(self.database) as db:
            old_count = db.execute("SELECT count(*) FROM passages").fetchone()[0]
            self.assertGreater(old_count, 1)
            db.execute("DELETE FROM chunks WHERE rowid=(SELECT max(rowid) FROM chunks)")
        self.restart()
        self.assertEqual(self.read(key)["revision_id"], first["revision_id"])
        self.ready("quasar", count=1)
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM chunks").fetchone()[0], old_count)
            self.assertEqual(db.execute("SELECT count(*) FROM passages").fetchone()[0], old_count)
            db.execute("UPDATE search_configuration SET version='rebuild-required'")
        self.restart()
        self.ready("quasar", count=1)
        self.assertEqual(self.read(key)["text"], first["text"])
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute("SELECT count(DISTINCT generation) FROM passages").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT count(*) FROM passages").fetchone()[0], old_count)

    def test_cleanup_during_blocked_index_preserves_active_pin(self):
        gate = self.gate("index-before-publish")
        key = self.prepare("quasar retained authoritative text")
        self.arrived("index-before-publish")
        first = self.read(key)
        (self.sources / "fixture.txt").unlink()
        self.configure(sources=[])
        # Release another session invokes retention-aware cleanup while publication is delayed.
        other = str(uuid.uuid4())
        self.result("release", {"start_id": str(uuid.uuid4())}, session=other)
        self.assertEqual(self.read(key)["text"], first["text"])
        gate.unlink()
        self.assertTrue(self.ready("quasar", count=1)["hits"])
        self.assertEqual(self.pins()[key], first["revision_id"])

    def test_full_length_10k_membership_and_retained_revisions(self):
        key = self.prepare("small native base document")
        self.ready("absenttoken", count=1)
        # Fixture a persisted cache: every authoritative row and posting has the same full-length
        # key/shape as the helper's own publication, including many ineligible historical revisions.
        version = None
        text = "scalefinal evidence"
        digest = hashlib.sha256(text.encode()).hexdigest()
        token = "t" + "scalefinal".encode().hex() + " t" + "evidence".encode().hex()
        target = None
        with sqlite3.connect(self.database) as db:
            version = db.execute("SELECT version FROM search_configuration").fetchone()[0]
            for index in range(9999):
                document = str(uuid.uuid4())
                revision = hashlib.sha256((document + "current").encode()).hexdigest()
                old = hashlib.sha256((document + "historical").encode()).hexdigest()
                target = document
                db.execute("INSERT INTO documents VALUES(?,?,?,1,?)", (document, f"/synthetic/{index}.txt", "synthetic", revision))
                db.execute("INSERT INTO session_documents VALUES(?,?,?,?,?,?,?,?)", (self.session, document, f"{index}.txt", "txt", f"/synthetic/{index}.txt", "/synthetic", "synthetic", revision))
                for identifier in [revision, old]:
                    db.execute("INSERT INTO revisions VALUES(?,?,?,?,?,?,1,1,0)", (identifier, document, digest, "synthetic-fixture", len(text), digest))
                    db.execute("INSERT INTO content_parts VALUES(?,0,?)", (identifier, text.encode()))
                    db.execute("INSERT INTO search_state VALUES(?,?,?,'ready',1)", (identifier, "synthetic-generation", version))
                    db.execute("INSERT INTO passages(revision_id,generation,ordinal,offset,end_offset,text) VALUES(?,?,0,0,?,?)", (identifier, "synthetic-generation", len(text), text))
                    row = db.execute("SELECT last_insert_rowid()").fetchone()[0]
                    db.execute("INSERT INTO chunks(rowid,revision_id,generation,text) VALUES(?,?,?,?)", (row, identifier, "synthetic-generation", token))
        started = time.monotonic()
        result = self.search("scalefinal")
        elapsed = time.monotonic() - started
        self.assertTrue(result["complete"], result)
        self.assertEqual(result["coverage"]["eligible_documents"], 10000)
        self.assertEqual(result["coverage"]["searched_documents"], 10000)
        self.assertTrue(result["truncated"])
        self.assertEqual(len(result["hits"]), 3)
        self.assertTrue(all(len(h["revision_id"]) == 64 for h in result["hits"]))
        self.assertLess(elapsed, 2)
        selected = self.search("scalefinal", [target])
        self.assertEqual([h["document_id"] for h in selected["hits"]], [target])
        self.assertEqual(selected["coverage"]["eligible_documents"], 1)
        print(f"10k full-key IPC query with 9999 retained revisions: {elapsed * 1000:.2f} ms", flush=True)


if __name__ == "__main__":
    unittest.main()
