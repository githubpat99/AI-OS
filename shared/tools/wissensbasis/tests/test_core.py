import contextlib
import io
import json
import os
import shutil
import sqlite3
import tempfile
import unittest
import uuid
import zipfile
from pathlib import Path
from unittest import mock

from wb import acl, cli

TOOL_DIR = str(Path(__file__).resolve().parents[1])


def run(*args: str):
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        code = cli.main(["--json", *args])
    text = buffer.getvalue().strip()
    payload = json.loads(text.splitlines()[-1]) if text else None
    return code, payload


def ok(*args: str):
    code, payload = run(*args)
    if code != 0 or not payload or not payload.get("ok"):
        raise AssertionError(f"wb {' '.join(args)} fehlgeschlagen: {code} {payload}")
    return payload["data"]


class WbTestCase(unittest.TestCase):
    def setUp(self):
        self.base = Path.home() / (".wb-tests-" + uuid.uuid4().hex[:8])
        self.base.mkdir()
        self.config_path = self.base / "config.json"
        self.env = mock.patch.dict(os.environ, {"WB_CONFIG": str(self.config_path), "PYTHONPATH": TOOL_DIR})
        self.env.start()
        self.source = self.base / "source"
        self._make_source()
        self.store = self.base / "store"

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.base, ignore_errors=True)

    def _make_source(self):
        (self.source / "sub").mkdir(parents=True)
        (self.source / "a.md").write_text(
            "# Architektur\n\nDie Zielarchitektur Transformation beschreibt den Umbau.\n\n## Zählregeln\n\nDie Zählregeln sind ungeprüft.\n",
            encoding="utf-8", newline="\n")
        (self.source / "b.txt").write_text("Volltextsuche mit Transformation und Quellenregister.\n", encoding="utf-8", newline="\n")
        (self.source / "c.html").write_text(
            "<html><body><h1>Quellen</h1><p>Quellenregister und Herkunft.</p><script>alert(1)</script></body></html>",
            encoding="utf-8", newline="\n")
        (self.source / "sub" / "note.md").write_text("# Notiz\n\nVertrauliche Steuernotiz mit Zählregeln.\n", encoding="utf-8", newline="\n")
        (self.source / ".gitkeep").write_text("", encoding="utf-8")
        (self.source / "invalid.md").write_bytes(bytes([195, 40]))
        (self.source / "empty.txt").write_text("", encoding="utf-8")
        (self.source / "a.pdf").write_text("%PDF-1.4 fake", encoding="utf-8")
        with zipfile.ZipFile(self.source / "d.docx", "w") as archive:
            archive.writestr(
                "word/document.xml",
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r>'
                "<w:t>Office Text mit Transformation</w:t></w:r></w:p></w:body></w:document>",
            )
        (self.source / "e.eml").write_text(
            "From: a@example.invalid\r\nTo: b@example.invalid\r\nSubject: Mailtest\r\n"
            "Date: Thu, 5 Nov 2026 10:00:00 +0000\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n"
            "Mailtext mit Transformation.\r\n", encoding="utf-8", newline="\n")

    def init_store(self):
        ok("init", "--root", str(self.store))
        return self.store

    def add_source(self, source_id="src-test", space="business", path=None):
        return ok("source", "add", "--id", source_id, "--name", "Testquelle", "--space", space,
                  "--kind", "folder", "--path", str(path or self.source), "--confidentiality", "internal")

    def import_source(self):
        return ok("import", "--source", "src-test", "--formats", "md,txt,html,docx,eml")

    def source_hashes(self):
        return {str(path.relative_to(self.source)): __import__("hashlib").sha256(path.read_bytes()).hexdigest()
                for path in sorted(self.source.rglob("*")) if path.is_file()}

    # --- Tests ---------------------------------------------------------------

    def test_init_guards_and_status(self):
        code, payload = run("init", "--root", str(Path(tempfile.gettempdir()) / ("wb-" + uuid.uuid4().hex)))
        self.assertEqual(code, 2)
        self.assertEqual(payload["error"]["code"], "store_temp")

        repo = self.base / "repo"
        (repo / ".git").mkdir(parents=True)
        code, payload = run("init", "--root", str(repo / "store"))
        self.assertEqual(code, 2)
        self.assertEqual(payload["error"]["code"], "store_repo")

        self.init_store()
        data = ok("status")
        self.assertEqual(data["summary"]["role"], "leader")
        self.assertEqual(data["summary"]["items"], 0)
        self.assertIn("irreplaceable_ledger", data["data_classes"])

    def test_import_provenance_idempotency_and_source_immutability(self):
        self.init_store()
        self.add_source()
        before = self.source_hashes()
        report = self.import_source()
        self.assertEqual(report["report"]["scanned"], 10)
        self.assertEqual(report["report"]["new_items"], 8)
        self.assertEqual(report["report"]["new_versions"], 8)
        self.assertEqual(report["report"]["failed"], 2)
        self.assertEqual(len(report["report"]["skipped"]), 2)
        self.assertEqual(after := self.source_hashes(), before)

        items = ok("item", "list")
        self.assertEqual(len(items), 8)
        statuses = {item["display_path"]: item["extraction_status"] for item in items}
        self.assertEqual(statuses["a.md"], "full")
        self.assertEqual(statuses["d.docx"], "partial")
        self.assertEqual(statuses["e.eml"], "partial")
        self.assertEqual(statuses["invalid.md"], "failed")
        self.assertEqual(statuses["empty.txt"], "failed")

        second = self.import_source()["report"]
        self.assertEqual(second["new_items"], 0)
        self.assertEqual(second["new_versions"], 0)
        self.assertEqual(second["unchanged"], 8)
        self.assertEqual(self.source_hashes(), after)

        item = next(entry for entry in items if entry["display_path"] == "a.md")
        detail = ok("item", "show", item["item_id"])
        self.assertEqual(len(detail["versions"]), 1)
        self.assertEqual(detail["versions"][0]["extraction"]["status"], "full")
        self.assertEqual(len(detail["provenance"]), 1)

    def test_original_readthrough(self):
        self.init_store()
        self.add_source()
        self.import_source()
        item = next(entry for entry in ok("item", "list") if entry["display_path"] == "a.md")
        out = self.base / "out"
        result = ok("original", item["item_id"], "--out", str(out))
        self.assertEqual((out / "a.md").read_text(encoding="utf-8"), (self.source / "a.md").read_text(encoding="utf-8"))
        self.assertEqual(result["content_hash"], item["content_hash"])
        code, payload = run("original", item["item_id"], "--out", str(out))
        self.assertEqual(code, 2)
        self.assertEqual(payload["error"]["code"], "original_exists")
        (self.source / "a.md").write_text("changed", encoding="utf-8")
        code, payload = run("original", item["item_id"], "--out", str(self.base / "out2"))
        self.assertEqual(code, 4)
        self.assertEqual(payload["error"]["code"], "original_changed")

    def test_search_and_index_rebuild(self):
        self.init_store()
        self.add_source()
        self.import_source()
        first = ok("search", "Transformation")
        self.assertGreaterEqual(len(first["results"]), 4)
        self.assertTrue(all(entry["citation"]["start"] >= 0 for entry in first["results"]))
        self.assertTrue(all(entry["source_id"] == "src-test" for entry in first["results"] if entry["type"] == "evidence"))
        self.assertEqual(ok("search", "Transformation", "--space", "private")["results"], [])

        signature = [(entry["type"], entry.get("item_id") or entry.get("knowledge_id"),
                      entry["snippet"], entry["citation"]["start"], entry["citation"]["end"]) for entry in first["results"]]
        (self.store / "index" / "search.sqlite3").unlink()
        code, payload = run("search", "Transformation")
        self.assertEqual(code, 2)
        self.assertEqual(payload["error"]["code"], "index_missing")
        rebuilt = ok("index", "rebuild")
        self.assertGreater(rebuilt["evidence_chunks"], 0)
        second = ok("search", "Transformation")
        second_signature = [(entry["type"], entry.get("item_id") or entry.get("knowledge_id"),
                             entry["snippet"], entry["citation"]["start"], entry["citation"]["end"]) for entry in second["results"]]
        self.assertEqual(signature, second_signature)

    def test_backup_restore_package_and_readonly(self):
        self.init_store()
        self.add_source()
        self.import_source()
        note = ok("note", "add", "--title", "Testnotiz", "--file", str(self.source / "b.txt"), "--space", "business")
        confirmed = ok("review", "confirm", note["knowledge_version_id"], "--note", "geprüft")
        self.assertEqual(confirmed["review_state"], "confirmed")
        code, payload = run("review", "confirm", note["knowledge_version_id"], "--basis-hash", "falsch")
        self.assertEqual(code, 6)
        self.assertEqual(payload["error"]["code"], "review_conflict")

        backup = self.base / "backup"
        ok("backup", "--out", str(backup))
        self.assertTrue((backup / "backup.json").exists())
        self.assertTrue((backup / "db" / "knowledge.sqlite3").exists())

        restored = self.base / "restored"
        ok("restore", "--from", str(backup), "--root", str(restored))
        self.assertEqual(len(ok("item", "list", "--root", str(restored))), 8)
        notes = ok("note", "list", "--root", str(restored))
        self.assertEqual(len(notes), 1)
        self.assertEqual(notes[0]["review_state"], "confirmed")
        self.assertTrue(ok("verify", "--root", str(restored))["ok"])

        package = self.base / "package"
        ok("package", "create", "--out", str(package))
        mirror = self.base / "mirror"
        ok("restore", "--from", str(package), "--root", str(mirror), "--readonly")
        code, payload = run("status", "--root", str(mirror))
        self.assertEqual(payload["meta"]["role"], "mirror")
        self.assertEqual(len(ok("search", "Transformation", "--root", str(mirror))["results"]), 5)
        code, payload = run("import", "--source", "src-test", "--root", str(mirror))
        self.assertEqual(code, 3)
        self.assertEqual(payload["error"]["code"], "store_readonly")
        code, payload = run("note", "add", "--title", "X", "--file", str(self.source / "b.txt"),
                            "--space", "business", "--root", str(mirror))
        self.assertEqual(code, 3)
        item = next(entry for entry in ok("item", "list", "--root", str(mirror)) if entry["display_path"] == "a.md")
        code, payload = run("original", item["item_id"], "--out", str(self.base / "mirror-out"), "--root", str(mirror))
        self.assertEqual(code, 4)
        self.assertEqual(payload["error"]["code"], "original_unavailable")

    def test_verify_detects_corrupt_blob(self):
        self.init_store()
        self.add_source()
        self.import_source()
        blob = next((self.store / "blobs" / "sha256").rglob("*"))
        while blob.is_dir():
            blob = next(blob.rglob("*"))
        blob.write_bytes(b"corrupted")
        code, payload = run("verify")
        self.assertEqual(code, 5)
        self.assertFalse(payload["ok"])
        self.assertFalse(payload["data"]["checks"]["blobs_intact"])

    def test_access_checks_use_effective_os_access(self):
        self.init_store()
        self.add_source()
        self.import_source()
        with mock.patch.object(acl.os, "access", return_value=False):
            self.assertFalse(ok("acl", "check", "--source", "src-test")["allowed"])
            report = ok("search", "Transformation")
            self.assertEqual(report["results"], [])
            self.assertGreater(report["filtered_by_access"], 0)
            item = next(entry for entry in ok("item", "list") if entry["display_path"] == "a.md")
            code, payload = run("original", item["item_id"], "--out", str(self.base / "denied"))
            self.assertEqual(code, 3)
            self.assertEqual(payload["error"]["code"], "original_denied")
            recheck = ok("acl", "recheck")
            self.assertEqual(recheck["mismatches"], 1)

    def test_mixed_requires_more_than_classification(self):
        self.init_store()
        self.add_source()
        self.import_source()
        note = ok("note", "add", "--title", "Gemischt", "--file", str(self.source / "a.md"), "--space", "mixed")
        decision = ok("acl", "check", "--knowledge", note["knowledge_id"], "--principal", "reader-business")
        self.assertFalse(decision["allowed"])
        self.assertTrue(any("derive_cross_space" in reason for reason in decision["reasons"]))
        self.assertTrue(any("nicht verifizierbar" in reason for reason in decision["reasons"]))
        code, payload = run("note", "show", note["knowledge_id"], "--principal", "reader-business")
        self.assertEqual(code, 3)
        self.assertEqual(payload["error"]["code"], "knowledge_denied")

    def test_evidence_supersession_marks_knowledge_and_keeps_history(self):
        self.init_store()
        self.add_source()
        self.import_source()
        item = next(entry for entry in ok("item", "list") if entry["display_path"] == "a.md")
        old_detail = ok("item", "show", item["item_id"])
        old_version = old_detail["current_version_id"]
        claim_body = self.base / "claim.md"
        claim_body.write_text("# Befund\n\nDie Zählregeln sind ungeprüft.\n", encoding="utf-8")
        claim = ok("knowledge", "add", "--kind", "claim", "--title", "Zählregeln ungeprüft",
                   "--file", str(claim_body), "--basis", old_version)
        claim_show = ok("knowledge", "show", claim["knowledge_id"])
        ok("review", "confirm", claim["knowledge_version_id"], "--basis-hash", claim_show["basis_hash"])
        unconfirmed = ok("knowledge", "add", "--kind", "claim", "--title", "Zählregeln ohne Prüfung",
                         "--file", str(claim_body), "--basis", old_version)
        self.assertEqual(ok("knowledge", "show", unconfirmed["knowledge_id"])["version"]["review_state"], "needs_review")
        note = ok("note", "add", "--title", "Unabhängige Notiz", "--file", str(self.source / "b.txt"),
                  "--space", "business")
        note_show = ok("note", "show", note["knowledge_id"])
        ok("review", "confirm", note["knowledge_version_id"], "--basis-hash", note_show["basis_hash"])

        (self.source / "a.md").write_text("# Architektur\n\nDie Zielarchitektur wurde geändert.\n", encoding="utf-8")
        report = self.import_source()["report"]
        self.assertEqual(report["new_versions"], 1)

        stale = ok("knowledge", "show", claim["knowledge_id"])
        self.assertEqual(stale["version"]["review_state"], "confirmation_stale")
        self.assertEqual(stale["reviews"][-1]["decision"], "confirmed")
        self.assertTrue(stale["reviews"][-1]["invalidated_at"])
        self.assertEqual(stale["reviews"][-1]["invalidated_by_version_id"],
                         ok("item", "show", item["item_id"])["versions"][-1]["version_id"])
        self.assertTrue(stale["provenance"])

        unconfirmed_stale = ok("knowledge", "show", unconfirmed["knowledge_id"])
        self.assertEqual(unconfirmed_stale["version"]["review_state"], "needs_review")
        self.assertEqual(unconfirmed_stale["reviews"], [])
        self.assertTrue(unconfirmed_stale["provenance"])

        untouched_note = ok("note", "show", note["knowledge_id"])
        self.assertEqual(untouched_note["version"]["review_state"], "confirmed")

        history = ok("evidence", old_version)
        self.assertFalse(history["is_current"])
        self.assertTrue(history["superseded_by"])
        self.assertIn("zielarchitektur transformation", history["text"].lower())
        links = {link["knowledge_id"]: link for link in history["knowledge_links"]}
        self.assertEqual(links[claim["knowledge_id"]]["review_state"], "confirmation_stale")
        self.assertEqual(links[unconfirmed["knowledge_id"]]["review_state"], "needs_review")
        self.assertEqual(history["pages"], [])

        updated = ok("item", "show", item["item_id"])
        self.assertEqual(len(updated["versions"]), 2)
        self.assertFalse(updated["versions"][0]["is_current"])
        self.assertEqual(updated["versions"][0]["superseded_by"], updated["versions"][1]["version_id"])
        self.assertTrue(updated["versions"][1]["is_current"])
        self.assertTrue(ok("verify")["ok"])

    def test_revision_keeps_confirmation_and_history(self):
        self.init_store()
        self.add_source()
        self.import_source()
        item = next(entry for entry in ok("item", "list") if entry["display_path"] == "a.md")
        evidence = ok("item", "show", item["item_id"])["current_version_id"]
        first_body = self.base / "revision-v1.md"
        first_body.write_text("# Befund\n\nErste Fassung mit Beleg.\n", encoding="utf-8")
        claim = ok("knowledge", "add", "--kind", "claim", "--title", "Revision", "--file",
                   str(first_body), "--basis", evidence)
        first_show = ok("knowledge", "show", claim["knowledge_id"])
        ok("review", "confirm", claim["knowledge_version_id"], "--basis-hash", first_show["basis_hash"],
           "--note", "Erste Pruefung")

        revised_body = self.base / "revision-v2.md"
        revised_body.write_text("# Befund\n\nZweite Fassung mit praeziserem Beleg.\n", encoding="utf-8")
        revised = ok("knowledge", "revise", claim["knowledge_id"], "--file", str(revised_body),
                     "--base-version", claim["knowledge_version_id"], "--reason", "Praezisiert")
        self.assertEqual(revised["version_no"], 2)
        self.assertEqual(revised["review_state"], "needs_review")

        detail = ok("knowledge", "show", claim["knowledge_id"])
        self.assertEqual(detail["version"]["id"], revised["knowledge_version_id"])
        self.assertEqual(detail["version"]["review_state"], "needs_review")
        self.assertEqual([entry["versionNo"] for entry in detail["versions"]], [1, 2])
        self.assertEqual(detail["versions"][0]["reviewState"], "confirmed")
        self.assertTrue(detail["versions"][0]["reviews"])
        self.assertEqual(detail["versions"][0]["reviews"][0]["decision"], "confirmed")
        self.assertEqual(detail["history"][-1]["type"], "confirmation_superseded")
        version_events = [entry for entry in detail["history"] if entry["type"] == "version"]
        self.assertEqual(version_events[-1]["reason"], "Praezisiert")
        self.assertIn("confirmed", [entry["type"] for entry in detail["history"]])
        self.assertIn("confirmation_superseded", [entry["type"] for entry in detail["history"]])

        old = ok("knowledge", "version", claim["knowledge_version_id"])
        self.assertIn("Erste Fassung", old["body"])
        self.assertEqual(old["reviews"][0]["decision"], "confirmed")
        self.assertFalse(old["is_current"])

        code, payload = run("knowledge", "revise", claim["knowledge_id"], "--file", str(revised_body),
                            "--base-version", revised["knowledge_version_id"])
        self.assertEqual(code, 2)
        self.assertEqual(payload["error"]["code"], "knowledge_unchanged")

        new_show = ok("knowledge", "show", claim["knowledge_id"])
        ok("review", "confirm", revised["knowledge_version_id"], "--basis-hash", new_show["basis_hash"])
        self.assertEqual(ok("knowledge", "show", claim["knowledge_id"])["version"]["review_state"], "confirmed")

    def test_snippet_offsets_use_original_text(self):
        from wb.indexer import _snippet
        text = "Straße und Transformation im Text"
        expected = text.index("Transformation")
        _snippet_text, citation = _snippet(text, ["Transformation"], 0)
        self.assertEqual(citation["start"], expected)
        self.assertEqual(text[citation["start"]:citation["end"]], "Transformation")

    def test_pdf_text_import_keeps_page_references(self):
        self.init_store()
        self.add_source()
        fake = {"pages": [
            {"page": 1, "text": "Inhaltsverzeichnis und Einleitung mit ausreichend Text fuer diese Seite."},
            {"page": 2, "text": "Die Zaehlregeln sind ungeprueft und werden spaeter geprueft."},
        ], "total_pages": 2, "max_pages": 80}
        with mock.patch("wb.extract.run_pdf_worker", return_value=fake):
            report = ok("import", "--source", "src-test", "--formats", "pdf")["report"]
        self.assertEqual(report["new_items"], 1)
        self.assertEqual(report["ocr_pending"], 0)
        item = next(entry for entry in ok("item", "list") if entry["display_path"] == "a.pdf")
        self.assertEqual(item["extraction_status"], "partial")
        detail = ok("item", "show", item["item_id"])
        extraction = detail["versions"][0]["extraction"]
        self.assertEqual([page["page"] for page in extraction["pages"]], [1, 2])
        self.assertEqual(extraction["pages"][1]["chars"], len("Die Zaehlregeln sind ungeprueft und werden spaeter geprueft."))
        result = ok("search", "Zaehlregeln")
        self.assertEqual(len(result["results"]), 1)
        self.assertEqual(result["results"][0]["page"], 2)
        text = ok("evidence", detail["current_version_id"])["text"]
        self.assertEqual(text[result["results"][0]["citation"]["start"]:result["results"][0]["citation"]["end"]],
                         "Zaehlregeln")
        self.assertTrue(ok("verify")["ok"])

    def test_pdf_ocr_is_explicit_step_and_keeps_old_extraction(self):
        self.init_store()
        self.add_source()
        text_pages = {"pages": [
            {"page": 1, "text": "Titelblatt mit einem langen Beschreibungstext, der nicht als Scan gilt."},
            {"page": 2, "text": ""},
        ], "total_pages": 2, "max_pages": 80}
        with mock.patch("wb.extract.run_pdf_worker", return_value=text_pages):
            report = ok("import", "--source", "src-test", "--formats", "pdf")["report"]
        self.assertEqual(report["ocr_pending"], 1)
        item = next(entry for entry in ok("item", "list") if entry["display_path"] == "a.pdf")
        version_id = ok("item", "show", item["item_id"])["current_version_id"]
        result = ok("search", "Titelblatt")
        self.assertEqual(result["results"][0]["page"], 1)

        ocr_pages = {"pages": [{"page": 2, "text": "Erkannte OCR Zeile mit Schluesselbegriff."}]}
        with mock.patch("wb.extract.run_pdf_worker", return_value=ocr_pages):
            outcome = ok("ocr", version_id)
        self.assertEqual(outcome["ocr"]["ocr_pages"], [2])
        self.assertEqual(outcome["ocr"]["status"], "partial")
        detail = ok("item", "show", item["item_id"])
        self.assertEqual(len(detail["versions"]), 1)
        extraction = detail["versions"][0]["extraction"]
        self.assertEqual(extraction["extractor"], "pdf-ocr")
        self.assertTrue(extraction["pages"][1]["ocr"])
        self.assertIn("Schluesselbegriff", ok("evidence", version_id)["text"])
        hit = ok("search", "Schluesselbegriff")
        self.assertEqual(len(hit["results"]), 1)
        self.assertEqual(hit["results"][0]["page"], 2)
        self.assertTrue(ok("verify")["ok"])

        code, payload = run("ocr", version_id)
        self.assertEqual(code, 2)
        self.assertEqual(payload["error"]["code"], "ocr_none")

    def test_pdf_without_pages_rejects_ocr(self):
        self.init_store()
        self.add_source()
        with mock.patch("wb.extract.run_pdf_worker", return_value={"pages": [], "total_pages": 0, "max_pages": 80}):
            ok("import", "--source", "src-test", "--formats", "pdf")
        item = next(entry for entry in ok("item", "list") if entry["display_path"] == "a.pdf")
        version_id = ok("item", "show", item["item_id"])["current_version_id"]
        code, payload = run("ocr", version_id)
        self.assertEqual(code, 2)
        self.assertEqual(payload["error"]["code"], "ocr_not_pdf")

    def test_pdf_page_metadata_is_clamped_at_text_limit(self):
        from wb.extract import MAX_CHARS, _pdf_pages
        pages = [{"page": 1, "text": "A" * 1_000_000}, {"page": 2, "text": "B" * 1_000_000}]
        built = _pdf_pages(pages)
        self.assertTrue(built["truncated"])
        self.assertEqual(len(built["text"]), MAX_CHARS)
        for page in built["pages"]:
            self.assertLessEqual(page["end"], len(built["text"]))
            self.assertEqual(page["chars"], page["end"] - page["start"])
        self.assertLessEqual(len(built["pages"]), 2)

    def test_backup_inside_repository_is_refused(self):
        self.init_store()
        self.add_source()
        self.import_source()
        repo = self.base / "repo2"
        (repo / ".git").mkdir(parents=True)
        code, payload = run("backup", "--out", str(repo / "backup"))
        self.assertEqual(code, 2)
        self.assertEqual(payload["error"]["code"], "backup_repo")

    def test_json_contract(self):
        self.init_store()
        for args in (("status",), ("doctor",), ("source", "list"), ("item", "list"), ("verify",)):
            code, payload = run(*args)
            self.assertEqual(code, 0)
            self.assertEqual(payload["schema"], "wb/v1")
            self.assertTrue(payload["ok"])
            self.assertIn("tool_version", payload["meta"])
        code, payload = run("search", "nichts")
        self.assertEqual(code, 2)
        self.assertEqual(payload["schema"], "wb/v1")
        self.assertFalse(payload["ok"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
