"""Betrieb: Verify, konsistentes Backup/Restore, Read-only-Paket, GC, Doctor."""
from __future__ import annotations

import json
import os
import shutil
import sqlite3
import time
import uuid
from pathlib import Path

from . import __version__, acl
from .config import binding_for
from .store import (DATA_CLASSES, SCHEMA_VERSION, STORE_SCHEMA, Store, assert_safe_store_root,
                    open_store, read_manifest, store_summary)
from .util import WbError, atomic_write_text, binding_fingerprint, sha256_file, utc_now

BACKUP_SCHEMA = "wb/backup/v1"
PACKAGE_SCHEMA = "wb/package/v1"


def _counts(store) -> dict:
    summary = store_summary(store)
    status = {
        row["status"]: row["count"]
        for row in store.db.execute(
            "SELECT status, count(*) AS count FROM extraction WHERE is_current=1 GROUP BY status"
        ).fetchall()
    }
    summary["extraction_status"] = status
    return summary


def _prepare_target(path: Path) -> None:
    path = path.expanduser().resolve()
    if path.exists() and any(path.iterdir()):
        raise WbError(f"Zielverzeichnis ist nicht leer: {path}", "backup_target")
    path.mkdir(parents=True, exist_ok=True)


def _copy_database(store, target: Path) -> dict:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.unlink()
    destination = sqlite3.connect(str(target))
    try:
        store.db.backup(destination)
        check = destination.execute("PRAGMA integrity_check").fetchone()[0]
        if check != "ok":
            raise WbError(f"Backup-Datenbank ist nicht integer: {check}", "backup_integrity", 5, False)
    finally:
        destination.close()
    return {"rel": target.name, "sha256": sha256_file(target), "size": target.stat().st_size}


def backup(store, out_dir: str) -> dict:
    out = Path(out_dir).expanduser().resolve()
    from .store import find_git_root
    if find_git_root(out) is not None:
        raise WbError("Sicherungen duerfen nicht in einem Git-Repository liegen.", "backup_repo")
    if out == store.root or store.root in out.parents:
        raise WbError("Sicherung darf nicht innerhalb des Stores liegen.", "backup_target")
    _prepare_target(out)
    (out / "db").mkdir(parents=True, exist_ok=True)
    db_info = _copy_database(store, out / "db" / "knowledge.sqlite3")
    blobs = []
    for row in store.db.execute("SELECT hash, rel, size FROM blob ORDER BY hash").fetchall():
        source = store.root / row["rel"]
        target = out / row["rel"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        if sha256_file(target) != row["hash"]:
            raise WbError(f"Blob im Backup beschaedigt: {row['hash'][:12]}…", "backup_blob", 5, False)
        blobs.append({"hash": row["hash"], "rel": row["rel"], "size": row["size"]})
    journal = []
    source_journal = store.root / "journal"
    if source_journal.exists():
        for path in sorted(source_journal.glob("events-*.jsonl")):
            target = out / "journal" / path.name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
            journal.append({"rel": f"journal/{path.name}", "sha256": sha256_file(target)})
    shutil.copy2(store.root / "MANIFEST.json", out / "store-manifest.json")
    manifest = {
        "schema": BACKUP_SCHEMA,
        "created_at": utc_now(),
        "store_id": store.manifest["store_id"],
        "role": store.role,
        "tool_version": __version__,
        "schema_version": SCHEMA_VERSION,
        "db": db_info,
        "blobs": blobs,
        "journal": journal,
        "counts": _counts(store),
        "data_classes": DATA_CLASSES,
    }
    atomic_write_text(out / "backup.json", json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    if not store.readonly:
        store.event("backup.created", "store", store.manifest["store_id"],
                    {"target": str(out), "blobs": len(blobs), "db_sha256": db_info["sha256"]})
    return {"target": str(out), "db": db_info, "blobs": len(blobs), "journal_files": len(journal),
            "counts": manifest["counts"]}


def _read_manifest(directory: Path) -> dict:
    for name, schema in (("backup.json", BACKUP_SCHEMA), ("package.json", PACKAGE_SCHEMA)):
        path = directory / name
        if path.exists():
            try:
                manifest = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                raise WbError(f"Manifest ist nicht lesbar: {exc}", "restore_manifest") from exc
            if manifest.get("schema") != schema:
                raise WbError("Unbekanntes Paketformat.", "restore_manifest")
            return manifest
    raise WbError("Weder backup.json noch package.json gefunden.", "restore_manifest")


def restore(from_dir: str, root: str, readonly: bool = False, rebuild: bool = True) -> dict:
    source = Path(from_dir).expanduser().resolve()
    target = Path(root).expanduser().resolve()
    manifest = _read_manifest(source)
    assert_safe_store_root(target)
    if target.exists() and any(target.iterdir()):
        raise WbError(f"Zielverzeichnis ist nicht leer: {target}", "restore_target")
    db_entry = manifest.get("db") or {}
    db_source = source / "db" / "knowledge.sqlite3"
    if not db_source.exists():
        raise WbError("Datenbank im Paket fehlt.", "restore_db", 5, False)
    if db_entry.get("sha256") and sha256_file(db_source) != db_entry["sha256"]:
        raise WbError("Datenbank im Paket stimmt nicht mit dem Manifest ueberein.", "restore_integrity", 5, False)
    for blob in manifest.get("blobs", []):
        path = source / blob["rel"]
        if not path.exists() or sha256_file(path) != blob["hash"]:
            raise WbError(f"Blob im Paket fehlt oder ist beschaedigt: {blob['hash'][:12]}…", "restore_integrity", 5, False)
    for directory in ("db", "blobs", "index", "journal", "exports", "tmp", "state", "locks"):
        (target / directory).mkdir(parents=True, exist_ok=True)
    shutil.copy2(db_source, target / "db" / "knowledge.sqlite3")
    for blob in manifest.get("blobs", []):
        destination = target / blob["rel"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / blob["rel"], destination)
    for journal in manifest.get("journal", []):
        path = source / journal["rel"]
        if path.exists():
            copy_path = target / journal["rel"]
            copy_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, copy_path)
    store_manifest = {
        "schema": STORE_SCHEMA,
        "store_id": manifest.get("store_id") or ("wb-" + uuid.uuid4().hex[:16]),
        "role": "mirror" if readonly else "leader",
        "created_at": utc_now(),
        "tool_version": __version__,
        "schema_version": SCHEMA_VERSION,
        "data_classes": DATA_CLASSES,
        "restored_from": str(source),
        "restored_at": utc_now(),
    }
    atomic_write_text(target / "MANIFEST.json", json.dumps(store_manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    store = open_store(target, writable=False)
    try:
        check = store.db.execute("PRAGMA integrity_check").fetchone()[0]
        if check != "ok":
            raise WbError(f"Wiederhergestellte Datenbank ist nicht integer: {check}", "restore_integrity", 5, False)
        report = verify(store, None, full=True)
        if not report["ok"]:
            raise WbError("Wiederhergestellter Store hat Integritaetsfehler: " + "; ".join(report["errors"][:5]),
                          "restore_verify", 5, False)
        index_info = None
        if rebuild:
            from . import indexer
            index_info = indexer.rebuild(store)
        counts = _counts(store)
    finally:
        store.close()
    return {"root": str(target), "role": store_manifest["role"], "store_id": store_manifest["store_id"],
            "counts": counts, "index": index_info}


def package_create(store, out_dir: str) -> dict:
    out = Path(out_dir).expanduser().resolve()
    _prepare_target(out)
    # Backup legt db/, blobs/, journal/ an; das Paket ist ein eingefrorener Snapshot.
    info = backup(store, str(out))
    grants = [dict(row) for row in store.db.execute("SELECT * FROM grant_row ORDER BY id").fetchall()]
    sources = [dict(row) for row in store.db.execute(
        "SELECT id,name,kind,space,confidentiality,canonical,status FROM source ORDER BY id"
    ).fetchall()]
    package = {
        "schema": PACKAGE_SCHEMA,
        "readonly": True,
        "created_at": utc_now(),
        "source_store_id": store.manifest["store_id"],
        "source_role": store.role,
        "tool_version": __version__,
        "schema_version": SCHEMA_VERSION,
        "counts": info["counts"],
        "permissions_snapshot": {"grants": grants, "sources": sources},
        "notice": "Eingefrorener Schnappschuss. Keine aktive SQLite-Datenbank in OneDrive oeffnen; vor Nutzung lokal wiederherstellen.",
    }
    atomic_write_text(out / "package.json", json.dumps(package, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    return {"target": str(out), "counts": info["counts"], "readonly": True}


def verify(store, config_or_root=None, full: bool = True, access: bool = False) -> dict:
    errors: list[str] = []
    warnings: list[str] = []
    checks = {}

    def check(name: str, condition: bool, message: str, warning: bool = False) -> None:
        checks[name] = bool(condition)
        if not condition:
            (warnings if warning else errors).append(message)

    integrity = store.db.execute("PRAGMA integrity_check").fetchone()[0]
    check("sqlite_integrity", integrity == "ok", f"SQLite-Integritaet: {integrity}")
    foreign = store.db.execute("PRAGMA foreign_key_check").fetchall()
    check("foreign_keys", not foreign, f"{len(foreign)} Fremdschluesselverletzungen")
    version = store.db.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
    check("schema_version", bool(version) and int(version[0]) == SCHEMA_VERSION, "Schema-Version passt nicht")

    versions = store.db.execute("SELECT v.*, (SELECT count(*) FROM extraction e WHERE e.version_id=v.id AND e.is_current=1) AS current_extractions FROM version v").fetchall()
    check("versions_have_extraction", all(row["current_extractions"] == 1 for row in versions),
          "Nicht jede Fassung hat genau eine aktuelle Extraktion")
    items = store.db.execute("SELECT id FROM item").fetchall()
    for item in items:
        seqs = [row[0] for row in store.db.execute("SELECT seq_no FROM version WHERE item_id=? ORDER BY seq_no", (item["id"],))]
        if seqs != list(range(1, len(seqs) + 1)):
            errors.append(f"Fassungsnummern nicht lueckenlos: {item['id']}")
    check("version_sequences", not any("Fassungsnummern" in error for error in errors), "Fassungsnummern pruefen")
    chain_broken = store.db.execute(
        "SELECT v.id FROM version v WHERE v.seq_no > 1 AND (v.supersedes_version_id IS NULL OR v.supersedes_version_id != "
        "(SELECT id FROM version p WHERE p.item_id=v.item_id AND p.seq_no=v.seq_no-1))"
    ).fetchall()
    check("version_chain", not chain_broken, f"{len(chain_broken)} Fassungen ohne korrekte Vorgaengerkette")

    missing_blobs = []
    orphan_files = []
    referenced = set()
    for row in store.db.execute("SELECT hash, rel, size FROM blob ORDER BY hash").fetchall():
        referenced.add(row["hash"])
        path = store.root / row["rel"]
        if not path.exists():
            missing_blobs.append(row["hash"])
            continue
        if path.stat().st_size != row["size"] or sha256_file(path) != row["hash"]:
            missing_blobs.append(row["hash"])
    check("blobs_intact", not missing_blobs, f"{len(missing_blobs)} Text-Blobs fehlen oder sind beschaedigt")
    if full:
        blob_dir = store.root / "blobs" / "sha256"
        if blob_dir.exists():
            for path in blob_dir.rglob("*"):
                if path.is_file() and path.name not in referenced:
                    orphan_files.append(path.name)
        check("blobs_referenced", not orphan_files, f"{len(orphan_files)} unreferenzierte Blob-Dateien", warning=True)

    extraction_blobs = store.db.execute(
        "SELECT e.text_hash FROM extraction e WHERE e.text_hash IS NOT NULL"
    ).fetchall()
    missing_text = [row["text_hash"] for row in extraction_blobs if row["text_hash"] not in referenced]
    check("extraction_text", not missing_text, f"{len(missing_text)} Extraktionstexte ohne Blob")

    bad_pages = []
    page_rows = store.db.execute(
        "SELECT e.id, e.text_hash, e.pages_json FROM extraction e WHERE e.pages_json IS NOT NULL AND e.pages_json != ''"
    ).fetchall()
    for row in page_rows:
        try:
            pages = json.loads(row["pages_json"])
        except ValueError:
            bad_pages.append(row["id"])
            continue
        if not isinstance(pages, list):
            bad_pages.append(row["id"])
            continue
        if not pages:
            continue
        try:
            text = store.read_blob(row["text_hash"]).decode("utf-8", "strict") if row["text_hash"] else ""
        except WbError:
            # Der defekte Blob wird bereits ueber blobs_intact gemeldet.
            continue
        seen = set()
        for page in pages:
            number = page.get("page") if isinstance(page, dict) else None
            start = page.get("start") if isinstance(page, dict) else None
            end = page.get("end") if isinstance(page, dict) else None
            chars = page.get("chars") if isinstance(page, dict) else None
            if (not isinstance(number, int) or number in seen or not isinstance(start, int)
                    or not isinstance(end, int) or start < 0 or end < start or end > len(text)
                    or chars != end - start):
                bad_pages.append(row["id"])
                break
            seen.add(number)
    check("pages_consistent", not bad_pages, f"{len(bad_pages)} PDF-Seitenmetadaten inkonsistent")

    confirmed = store.db.execute(
        "SELECT kv.id, kv.basis_json, r.basis_hash FROM knowledge_version kv JOIN review r ON r.knowledge_version_id=kv.id "
        "WHERE kv.review_state='confirmed' AND r.decision='confirmed' ORDER BY r.decided_at"
    ).fetchall()
    for row in confirmed:
        from .ledger import basis_hash
        if basis_hash(json.loads(row["basis_json"])) != row["basis_hash"]:
            errors.append(f"Bestaetigungsbasis stimmt nicht: {row['id']}")
    check("review_basis", not any("Bestaetigungsbasis" in error for error in errors), "Bestaetigungsbasen pruefen")

    knowledge = store.db.execute("SELECT k.*, kv.id AS kv_id, kv.effective_space, kv.effective_confidentiality FROM knowledge k "
                                 "LEFT JOIN knowledge_version kv ON kv.id=k.current_version_id").fetchall()
    for row in knowledge:
        if row["kv_id"] is None:
            errors.append(f"Wissen ohne aktuelle Fassung: {row['id']}")
        if row["kind"] in ("claim", "summary", "decision", "register_entry"):
            count = store.db.execute("SELECT count(*) FROM provenance WHERE knowledge_version_id=?", (row["kv_id"],)).fetchone()[0]
            if count == 0:
                errors.append(f"Belegpflichtige Wissensart ohne Herkunft: {row['id']}")
    check("knowledge_current", not any("Wissen ohne aktuelle Fassung" in error for error in errors), "Aktuelle Wissensfassungen pruefen")
    check("provenance_required", not any("Belegpflichtige" in error for error in errors), "Belegpflicht pruefen")

    if config_or_root is not None:
        config = config_or_root
        for source_row in store.db.execute("SELECT * FROM source").fetchall():
            binding = binding_for(config, source_row["id"])
            if not binding:
                continue
            row = acl.binding_row(store, source_row["id"])
            if row and binding.get("locator") and row["locator_fingerprint"] != binding_fingerprint(binding["locator"]):
                errors.append(f"Bindung passt nicht zur Konfiguration: {source_row['id']}")
            if access:
                observed = acl.observe_path(Path(binding["locator"]))
                checks[f"access_{source_row['id']}"] = observed["read"]
                if not observed["read"]:
                    warnings.append(f"Kein aktueller Lesezugriff: {source_row['id']} ({observed['detail']})")
    check("config_bindings", not any("Bindung passt nicht" in error for error in errors), "Konfigurationsbindungen pruefen")

    journal_files = sorted((store.root / "journal").glob("events-*.jsonl"))
    journal_events = 0
    for path in journal_files:
        with path.open("r", encoding="utf-8") as stream:
            journal_events += sum(1 for line in stream if line.strip())
    db_events = store.db.execute("SELECT count(*) FROM event").fetchone()[0]
    check("journal_mirror", journal_events == db_events, f"Journal ({journal_events}) und Ereignisse ({db_events}) weichen ab", warning=True)

    if store.readonly:
        checks["readonly_role"] = True
    report = {"ok": not errors, "errors": errors, "warnings": warnings, "checks": checks, "counts": _counts(store),
              "verified_at": utc_now(), "store_id": store.manifest["store_id"], "role": store.role}
    state = store.root / "state"
    state.mkdir(parents=True, exist_ok=True)
    atomic_write_text(state / ("verify-" + report["verified_at"].replace(":", "").replace(".", "") + ".json"),
                      json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    atomic_write_text(state / "health.json", json.dumps(
        {"last_verify_at": report["verified_at"], "last_verify_ok": report["ok"], "counts": report["counts"]},
        ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    return report


def doctor(store) -> dict:
    from .store import assert_safe_store_root, is_onedrive_path
    checks = {}
    problems = []
    checks["root_exists"] = store.root.exists()
    checks["manifest"] = (store.root / "MANIFEST.json").exists()
    try:
        assert_safe_store_root(store.root)
        checks["root_safe"] = True
    except WbError as exc:
        checks["root_safe"] = False
        problems.append(exc.message)
    checks["db"] = (store.root / "db" / "knowledge.sqlite3").exists()
    checks["wal"] = (store.root / "db" / "knowledge.sqlite3-wal").exists()
    checks["journal"] = (store.root / "journal").exists()
    try:
        free = shutil.disk_usage(store.root).free
        checks["disk_free_gb"] = round(free / (1024 ** 3), 1)
        if free < 2 * 1024 ** 3:
            problems.append("Weniger als 2 GB frei")
    except OSError:
        pass
    index_state = None
    try:
        from . import indexer
        index_state = indexer.index_status(store)
        checks["index"] = index_state["state"]
    except Exception:
        checks["index"] = "unknown"
    checks["onedrive"] = is_onedrive_path(store.root)
    if checks["onedrive"]:
        problems.append("Store liegt in OneDrive")
    return {"ok": not problems, "problems": problems, "checks": checks, "index": index_state,
            "summary": store_summary(store)}


def gc(store, older_than_hours: int = 24) -> dict:
    now = time.time()
    removed_tmp = 0
    for path in (store.root / "tmp").glob("*"):
        try:
            age = now - path.stat().st_mtime
        except OSError:
            continue
        if age > older_than_hours * 3600:
            shutil.rmtree(path, ignore_errors=True) if path.is_dir() else path.unlink(missing_ok=True)
            removed_tmp += 1
    removed_locks = 0
    lock = store.root / "locks" / "store.lock"
    if lock.exists():
        try:
            if now - lock.stat().st_mtime > 6 * 3600:
                lock.unlink(missing_ok=True)
                removed_locks += 1
        except OSError:
            pass
    removed_blobs = 0
    if not store.readonly:
        referenced = {row["hash"] for row in store.db.execute("SELECT hash FROM blob").fetchall()}
        blob_dir = store.root / "blobs" / "sha256"
        if blob_dir.exists():
            for path in blob_dir.rglob("*"):
                if not path.is_file() or path.name in referenced:
                    continue
                try:
                    if now - path.stat().st_mtime > 7 * 24 * 3600:
                        path.unlink()
                        removed_blobs += 1
                except OSError:
                    continue
    return {"removed_tmp": removed_tmp, "removed_stale_locks": removed_locks, "removed_orphan_blobs": removed_blobs}
