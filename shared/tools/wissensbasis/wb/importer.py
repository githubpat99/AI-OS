"""Lesender Import: scannen, hashen, Fassungen und Extraktion erfassen."""
from __future__ import annotations

import json
import os
import re
import stat
import time
from datetime import datetime, timezone
from pathlib import Path

from . import acl, ledger
from .config import binding_for
from .extract import SUPPORTED_FORMATS, TEXT_FORMATS, HTML_FORMATS, OFFICE_FORMATS, MAIL_FORMATS, extract_file
from .util import WbError, item_id, normalize_external_id, sha256_file, utc_now, version_id

EXCLUDED_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__", "dist", "build", ".next", "coverage", ".cache"}
EXCLUDED_NAMES = {".ds_store", "thumbs.db", "desktop.ini", ".gitkeep", ".gitattributes", ".gitignore"}
CREDENTIAL_PATTERN = re.compile(r"^(\.env($|\.)|credentials|secrets|.*\.(pem|key|pfx|p12)$)", re.IGNORECASE)
OFFICE_TEMP = re.compile(r"^~\$")
DEFAULT_FORMATS = (TEXT_FORMATS | HTML_FORMATS | OFFICE_FORMATS | MAIL_FORMATS)
DEFAULT_MAX_BYTES = 200 * 1024 * 1024

MEDIA_TYPES = {
    ".md": "text/markdown", ".markdown": "text/markdown", ".txt": "text/plain", ".log": "text/plain",
    ".csv": "text/csv", ".tsv": "text/tab-separated-values", ".json": "application/json",
    ".yaml": "application/yaml", ".yml": "application/yaml", ".xml": "application/xml",
    ".html": "text/html", ".htm": "text/html", ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ".eml": "message/rfc822", ".pdf": "application/pdf",
}


def _mtime_iso(value: float) -> str:
    return datetime.fromtimestamp(value, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _is_reparse(path: Path) -> bool:
    if path.is_symlink():
        return True
    try:
        attributes = path.stat(follow_symlinks=False).st_file_attributes
    except (OSError, AttributeError):
        return False
    return bool(attributes & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0))


def parse_formats(value: str | None) -> set[str]:
    if not value:
        return set(DEFAULT_FORMATS)
    requested = set()
    for token in value.split(","):
        token = token.strip().lower()
        if not token:
            continue
        if not token.startswith("."):
            token = "." + token
        requested.add(token)
    unknown = requested - SUPPORTED_FORMATS - {".pdf"}
    if unknown:
        raise WbError(f"Unbekannte Formate: {', '.join(sorted(unknown))}", "formats")
    return requested


def scan_source(locator: str, formats: set[str], max_bytes: int) -> tuple[list[dict], list[dict]]:
    root = Path(locator)
    if not root.is_dir():
        raise WbError(f"Quelle ist kein Verzeichnis: {root}", "source_not_directory", 2)
    entries: list[dict] = []
    skipped: list[dict] = []
    for folder, dirnames, filenames in os.walk(root, followlinks=False):
        folder_path = Path(folder)
        dirnames[:] = sorted(name for name in dirnames if name.casefold() not in EXCLUDED_DIRS and not _is_reparse(folder_path / name))
        for name in sorted(filenames):
            path = folder_path / name
            relative = path.relative_to(root).as_posix()
            lowered = name.casefold()
            if lowered in EXCLUDED_NAMES or OFFICE_TEMP.match(name):
                skipped.append({"path": relative, "reason": "technische Datei"})
                continue
            if CREDENTIAL_PATTERN.match(name):
                skipped.append({"path": relative, "reason": "Zugangsdatenkandidat; Inhalt nicht gelesen"})
                continue
            if _is_reparse(path):
                skipped.append({"path": relative, "reason": "symbolischer Verweis oder Junction"})
                continue
            try:
                info = path.stat()
            except OSError as exc:
                skipped.append({"path": relative, "reason": f"nicht lesbar: {exc}"})
                continue
            extension = path.suffix.casefold()
            if extension not in formats:
                if extension == ".pdf":
                    skipped.append({"path": relative, "reason": "PDF ausserhalb des gewaehlten Pilotprofils"})
                else:
                    skipped.append({"path": relative, "reason": f"Format {extension or '(ohne)'} nicht in der Allowlist"})
                continue
            if info.st_size > max_bytes:
                skipped.append({"path": relative, "reason": f"groesser als {max_bytes} Bytes"})
                continue
            entries.append({
                "path": path,
                "relative": relative,
                "extension": extension,
                "size": info.st_size,
                "mtime": info.st_mtime,
                "media_type": MEDIA_TYPES.get(extension, "application/octet-stream"),
            })
    return entries, skipped


def _latest_version(store, item: str):
    return store.db.execute("SELECT * FROM version WHERE item_id=? ORDER BY seq_no DESC LIMIT 1", (item,)).fetchone()


def _version_by_hash(store, item: str, content_hash: str):
    return store.db.execute("SELECT * FROM version WHERE item_id=? AND content_hash=?", (item, content_hash)).fetchone()


def import_source(store, config: dict, source_id: str, formats: set[str], max_bytes: int = DEFAULT_MAX_BYTES,
                  dry_run: bool = False) -> dict:
    store.require_writable()
    source = store.db.execute("SELECT * FROM source WHERE id=?", (source_id,)).fetchone()
    if source is None:
        raise WbError(f"Quelle {source_id} nicht gefunden.", "source_missing", 2)
    binding = binding_for(config, source_id)
    locator = binding.get("locator") if binding else None
    if not locator:
        raise WbError("Keine lokale Bindung fuer diese Quelle.", "source_binding", 2)
    if not binding.get("read", True):
        raise WbError("Leserecht fuer diese Quelle ist nicht erteilt.", "source_read_denied", 3)
    if dry_run:
        observed = acl.observe_path(Path(locator))
        if not observed["read"]:
            raise WbError(f"Quelle nicht lesbar: {observed['detail'] or 'kein Zugriff'}", "source_unreachable", 4)
    else:
        probe = acl.probe_binding(store, source, locator)
        if probe["state"] != "reachable":
            raise WbError(f"Quelle nicht lesbar: {probe['detail'] or probe['state']}", "source_unreachable", 4)

    started = time.time()
    entries, skipped = scan_source(locator, formats, max_bytes)
    report = {
        "source_id": source_id,
        "dry_run": dry_run,
        "profile_formats": sorted(formats),
        "scanned": len(entries) + len(skipped),
        "entries": len(entries),
        "new_items": 0,
        "new_versions": 0,
        "unchanged": 0,
        "failed": 0,
        "unsupported": 0,
        "ocr_pending": 0,
        "skipped": skipped,
        "errors": [],
        "text_bytes": 0,
    }
    if dry_run:
        for entry in entries:
            try:
                digest = sha256_file(entry["path"])
            except OSError as exc:
                report["errors"].append({"path": entry["relative"], "reason": str(exc)})
                continue
            existing = store.db.execute(
                "SELECT i.id AS item_id, v.content_hash FROM item i LEFT JOIN version v ON v.id=("
                "SELECT id FROM version WHERE item_id=i.id ORDER BY seq_no DESC LIMIT 1) "
                "WHERE i.source_id=? AND i.external_id=?",
                (source_id, normalize_external_id(entry["relative"])),
            ).fetchone()
            if existing and existing["content_hash"] == digest:
                report["unchanged"] += 1
            elif existing:
                report["new_versions"] += 1
            else:
                report["new_items"] += 1
        report["elapsed_seconds"] = round(time.time() - started, 3)
        return report

    run_id = "run-" + os.urandom(8).hex()
    with store.transaction():
        store.db.execute("INSERT INTO run(id,kind,started_at,status) VALUES(?,?,?,?)",
                         (run_id, "import", utc_now(), "running"))
    for entry in entries:
        observed = acl.observe_path(entry["path"])
        if not observed["read"]:
            report["skipped"].append({"path": entry["relative"], "reason": "tatsaechlicher Lesezugriff verweigert"})
            continue
        try:
            before = entry["path"].stat()
            digest = sha256_file(entry["path"])
            external = normalize_external_id(entry["relative"])
            item = item_id(source_id, external)
            existing_item = store.db.execute("SELECT * FROM item WHERE id=?", (item,)).fetchone()
            latest = _latest_version(store, item)
            now = utc_now()
            known = _version_by_hash(store, item, digest)
            if latest is not None and latest["content_hash"] == digest:
                with store.transaction():
                    store.db.execute("UPDATE item SET last_seen_at=?, removed_at=NULL WHERE id=?", (now, item))
                    store.db.execute("UPDATE version SET last_observed_at=? WHERE id=?", (now, latest["id"]))
                report["unchanged"] += 1
                continue
            if known is not None:
                with store.transaction():
                    store.db.execute("UPDATE item SET last_seen_at=?, removed_at=NULL WHERE id=?", (now, item))
                    store.db.execute("UPDATE version SET last_observed_at=? WHERE id=?", (now, known["id"]))
                report["unchanged"] += 1
                continue
            extraction = extract_file(entry["path"])
            after = entry["path"].stat()
            if after.st_size != before.st_size or after.st_mtime != before.st_mtime:
                raise WbError("Datei wurde waehrend des Imports veraendert; keine Fassung erstellt.", "source_changed", 4)
            text_hash = None
            if extraction["text"]:
                text_hash = store.put_blob(extraction["text"].encode("utf-8", "strict"), "text/plain; charset=utf-8")
                report["text_bytes"] += len(extraction["text"].encode("utf-8", "strict"))
            version = version_id(item, digest)
            seq = (latest["seq_no"] + 1) if latest else 1
            with store.transaction():
                if existing_item is None:
                    store.db.execute(
                        "INSERT INTO item(id,source_id,external_id,display_path,kind,media_type,first_seen_at,last_seen_at) "
                        "VALUES(?,?,?,?,?,?,?,?)",
                        (item, source_id, external, entry["relative"],
                         "mail" if entry["extension"] == ".eml" else "document", entry["media_type"], now, now),
                    )
                    report["new_items"] += 1
                    store.event("item.created", "item", item, {"source_id": source_id, "path": entry["relative"]})
                else:
                    store.db.execute("UPDATE item SET last_seen_at=?, removed_at=NULL WHERE id=?", (now, item))
                store.db.execute(
                    "INSERT INTO version(id,item_id,content_hash,size,media_type,seq_no,first_observed_at,last_observed_at,source_mtime,supersedes_version_id,original_stored) "
                    "VALUES(?,?,?,?,?,?,?,?,?,?,0)",
                    (version, item, digest, entry["size"], entry["media_type"], seq, now, now,
                     _mtime_iso(entry["mtime"]), latest["id"] if latest else None),
                )
                store.db.execute(
                    "INSERT INTO extraction(id,version_id,extractor,extractor_version,status,reason,text_hash,created_at,is_current,pages_json) "
                    "VALUES(?,?,?,?,?,?,?,?,1,?)",
                    ("ext-" + os.urandom(8).hex(), version, extraction["extractor"], extraction["extractor_version"],
                     extraction["status"], extraction["reason"], text_hash, now,
                     json.dumps(extraction.get("pages", []), ensure_ascii=False, sort_keys=True)),
                )
                store.event("version.created", "version", version,
                            {"item_id": item, "content_hash": digest, "seq_no": seq,
                             "extraction_status": extraction["status"], "original_stored": False})
                if latest is not None:
                    ledger.invalidate_evidence(store, latest["id"], version)
                report["new_versions"] += 1
            if extraction["status"] in ("failed", "unsupported"):
                report["failed"] += 1
            if extraction["status"] == "unsupported":
                report["unsupported"] += 1
            report["ocr_pending"] += len(extraction.get("pending_ocr", []))
        except (OSError, WbError) as exc:
            report["errors"].append({"path": entry["relative"], "reason": str(exc)})
            report["failed"] += 1
    with store.transaction():
        store.db.execute("UPDATE source_binding SET last_success_at=?, state='reachable', last_error=NULL WHERE source_id=? AND computer_id=?",
                         (utc_now(), source_id, store.computer_id()))
        store.db.execute("UPDATE run SET finished_at=?, status=?, counts_json=? WHERE id=?",
                         (utc_now(), "completed" if not report["errors"] else "completed_with_errors", _json_counts(report), run_id))
        store.event("import.completed", "source", source_id,
                    {"scanned": report["scanned"], "new_items": report["new_items"],
                     "new_versions": report["new_versions"], "unchanged": report["unchanged"],
                     "failed": report["failed"], "skipped": len(report["skipped"])})
    report["elapsed_seconds"] = round(time.time() - started, 3)
    return report


def _json_counts(report: dict) -> str:
    import json
    return json.dumps({key: report[key] for key in ("scanned", "entries", "new_items", "new_versions", "unchanged", "failed", "unsupported", "ocr_pending", "text_bytes")}, sort_keys=True)


def import_all(store, config: dict, formats: set[str], max_bytes: int, dry_run: bool) -> dict:
    sources = store.db.execute("SELECT id FROM source WHERE status='active' ORDER BY id").fetchall()
    reports = []
    for row in sources:
        try:
            reports.append(import_source(store, config, row["id"], formats, max_bytes, dry_run))
        except WbError as exc:
            reports.append({"source_id": row["id"], "error": {"code": exc.code, "message": exc.message}})
    return {"sources": reports}
