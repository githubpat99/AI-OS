"""Ledger-Abfragen, Originalabruf, Notizen und manuelle Bestaetigungen."""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import uuid
from pathlib import Path

from . import acl
from .config import binding_for
from .util import WbError, sha256_file, utc_now

SPACES = {"business", "private", "mixed"}
CONFIDENTIALITY = {"public", "internal", "confidential", "restricted"}


def list_items(store, source_id: str | None = None, limit: int = 100, include_removed: bool = False) -> list[dict]:
    sql = (
        "SELECT i.*, s.name AS source_name, s.space, v.id AS version_id, v.seq_no, v.content_hash, v.size, "
        "v.first_observed_at, v.last_observed_at, e.status AS extraction_status, e.reason AS extraction_reason "
        "FROM item i JOIN source s ON s.id=i.source_id "
        "LEFT JOIN version v ON v.id=(SELECT id FROM version WHERE item_id=i.id ORDER BY seq_no DESC LIMIT 1) "
        "LEFT JOIN extraction e ON e.version_id=v.id AND e.is_current=1 "
        "WHERE (? IS NULL OR i.source_id=?) AND (? OR i.removed_at IS NULL) ORDER BY s.id, i.external_id LIMIT ?"
    )
    rows = store.db.execute(sql, (source_id, source_id, 1 if include_removed else 0, limit)).fetchall()
    return [{
        "item_id": row["id"],
        "source_id": row["source_id"],
        "source_name": row["source_name"],
        "space": row["space"],
        "display_path": row["display_path"],
        "external_id": row["external_id"],
        "removed": row["removed_at"] is not None,
        "version_id": row["version_id"],
        "seq_no": row["seq_no"],
        "content_hash": row["content_hash"],
        "size": row["size"],
        "observed_at": row["last_observed_at"],
        "extraction_status": row["extraction_status"],
        "extraction_reason": row["extraction_reason"],
    } for row in rows]


def _resolve(store, identifier: str):
    item = None
    version = None
    if identifier.startswith("ver-"):
        version = store.db.execute("SELECT * FROM version WHERE id=?", (identifier,)).fetchone()
        if version is None:
            raise WbError(f"Fassung {identifier} nicht gefunden.", "version_missing", 2)
        item = store.db.execute("SELECT * FROM item WHERE id=?", (version["item_id"],)).fetchone()
    else:
        item = store.db.execute("SELECT * FROM item WHERE id=?", (identifier,)).fetchone()
        if item is None:
            raise WbError(f"Element {identifier} nicht gefunden.", "item_missing", 2)
        version = store.db.execute("SELECT * FROM version WHERE item_id=? ORDER BY seq_no DESC LIMIT 1", (item["id"],)).fetchone()
    if item is None:
        raise WbError(f"Element zu {identifier} nicht gefunden.", "item_missing", 2)
    return item, version


def _pages_of(extraction) -> list[dict]:
    if extraction is None or "pages_json" not in extraction.keys() or not extraction["pages_json"]:
        return []
    try:
        pages = json.loads(extraction["pages_json"])
    except ValueError:
        return []
    return pages if isinstance(pages, list) else []


def item_detail(store, config: dict, identifier: str) -> dict:
    item, current = _resolve(store, identifier)
    source = store.db.execute("SELECT * FROM source WHERE id=?", (item["source_id"],)).fetchone()
    versions = []
    latest_id = store.db.execute("SELECT id FROM version WHERE item_id=? ORDER BY seq_no DESC LIMIT 1",
                                 (item["id"],)).fetchone()[0]
    for row in store.db.execute("SELECT * FROM version WHERE item_id=? ORDER BY seq_no", (item["id"],)).fetchall():
        extraction = store.db.execute(
            "SELECT * FROM extraction WHERE version_id=? AND is_current=1", (row["id"],)
        ).fetchone()
        successor = store.db.execute("SELECT id FROM version WHERE supersedes_version_id=? LIMIT 1",
                                     (row["id"],)).fetchone()
        versions.append({
            "version_id": row["id"],
            "seq_no": row["seq_no"],
            "content_hash": row["content_hash"],
            "size": row["size"],
            "first_observed_at": row["first_observed_at"],
            "last_observed_at": row["last_observed_at"],
            "source_mtime": row["source_mtime"],
            "original_stored": bool(row["original_stored"]),
            "supersedes_version_id": row["supersedes_version_id"],
            "is_current": row["id"] == latest_id,
            "superseded_by": successor["id"] if successor else None,
            "extraction": None if extraction is None else {
                "status": extraction["status"],
                "extractor": extraction["extractor"],
                "extractor_version": extraction["extractor_version"],
                "reason": extraction["reason"],
                "text_hash": extraction["text_hash"],
                "pages": _pages_of(extraction),
            },
        })
    binding = binding_for(config, source["id"]) if config else None
    access = acl.source_access(store, source, store.meta("actor", "owner"),
                               binding.get("locator") if binding else None) if config else None
    return {
        "item": {
            "item_id": item["id"],
            "source_id": item["source_id"],
            "source_name": source["name"],
            "space": source["space"],
            "confidentiality": source["confidentiality"],
            "display_path": item["display_path"],
            "external_id": item["external_id"],
            "media_type": item["media_type"],
            "register_id": item["register_id"],
            "removed_at": item["removed_at"],
            "first_seen_at": item["first_seen_at"],
            "last_seen_at": item["last_seen_at"],
        },
        "current_version_id": current["id"] if current else None,
        "versions": versions,
        "source_access": access,
        "provenance": provenance_for_item(store, item["id"]),
    }


def provenance_for_item(store, item_id: str) -> list[dict]:
    rows = store.db.execute(
        "SELECT v.id AS version_id, v.content_hash, v.first_observed_at, e.id AS extraction_id, "
        "e.extractor, e.extractor_version, e.status, e.reason, e.text_hash "
        "FROM version v LEFT JOIN extraction e ON e.version_id=v.id AND e.is_current=1 "
        "WHERE v.item_id=? ORDER BY v.seq_no",
        (item_id,),
    ).fetchall()
    return [dict(row) for row in rows]


def original(store, config: dict, identifier: str, out_dir: str, force: bool = False) -> dict:
    item, version = _resolve(store, identifier)
    if version is None:
        raise WbError("Keine Fassung vorhanden.", "version_missing", 2)
    if store.readonly:
        raise WbError("Spiegelstore: Originalabruf ist ohne Quellenzugriff nicht moeglich.", "original_unavailable", 4)
    source = store.db.execute("SELECT * FROM source WHERE id=?", (item["source_id"],)).fetchone()
    binding = binding_for(config, item["source_id"])
    locator = binding.get("locator") if binding else None
    if not locator:
        raise WbError("Keine lokale Bindung fuer diese Quelle.", "source_binding", 2)
    access = acl.source_access(store, source, store.meta("actor", "owner"), locator)
    if not access["allowed"]:
        raise WbError("Original nicht zugaenglich: " + "; ".join(access["reasons"]), "original_denied", 3)
    source_path = Path(locator) / item["display_path"].replace("/", os.sep)
    if not source_path.is_file():
        raise WbError("Originaldatei ist nicht mehr vorhanden.", "original_missing", 4)
    digest = sha256_file(source_path)
    if digest != version["content_hash"]:
        raise WbError("Original weicht von der erfassten Fassung ab. Kein Abruf ohne Uebereinstimmung.", "original_changed", 4)
    target_dir = Path(out_dir).expanduser().resolve()
    if target_dir == Path(locator).resolve() or Path(locator).resolve() in target_dir.parents:
        raise WbError("Ziel darf nicht innerhalb der Quelle liegen.", "original_target")
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / Path(item["display_path"]).name
    if target.exists() and not force:
        raise WbError(f"Ziel existiert bereits: {target}", "original_exists", 2)
    shutil.copyfile(source_path, target)
    if sha256_file(target) != digest:
        target.unlink(missing_ok=True)
        raise WbError("Kopie stimmt nicht mit dem Original ueberein.", "original_copy", 5, False)
    store.event("original.retrieved", "version", version["id"],
                {"item_id": item["id"], "content_hash": digest, "target": str(target)})
    return {"item_id": item["id"], "version_id": version["id"], "content_hash": digest, "target": str(target)}


def add_note(store, title: str, body_path: str, space: str, confidentiality: str | None = None, author: str | None = None) -> dict:
    store.require_writable()
    if space not in SPACES:
        raise WbError("Wissensraum muss business, private oder mixed sein.", "note_space")
    body_file = Path(body_path).expanduser()
    if not body_file.exists():
        raise WbError(f"Notizdatei nicht gefunden: {body_file}", "note_body")
    body = body_file.read_text(encoding="utf-8", errors="strict")
    confidentiality = confidentiality or ("confidential" if space in ("business", "private") else "restricted")
    if confidentiality not in CONFIDENTIALITY:
        raise WbError("Unbekannte Vertraulichkeit.", "note_confidentiality")
    author = author or store.meta("actor", "owner")
    content_hash = store.put_blob(body.encode("utf-8", "strict"), "text/markdown; charset=utf-8")
    knowledge = "knw-" + uuid.uuid4().hex
    version = "knv-" + uuid.uuid4().hex
    now = utc_now()
    with store.transaction():
        store.db.execute(
            "INSERT INTO knowledge(id,kind,title,space,confidentiality,canonical,created_by,created_at,current_version_id) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            (knowledge, "note", title.strip(), space, confidentiality, 1, author, now, version),
        )
        store.db.execute(
            "INSERT INTO knowledge_version(id,knowledge_id,version_no,content_hash,author,created_at,lifecycle,review_state,basis_json,effective_space,effective_confidentiality) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (version, knowledge, 1, content_hash, author, now, "draft", "unverified", "[]", space, confidentiality),
        )
        store.event("knowledge.created", "knowledge", knowledge,
                    {"kind": "note", "space": space, "version_id": version, "basis": []})
    return {"knowledge_id": knowledge, "knowledge_version_id": version, "space": space,
            "confidentiality": confidentiality, "review_state": "unverified"}


def list_notes(store, limit: int = 100) -> list[dict]:
    rows = store.db.execute(
        "SELECT k.*, kv.id AS version_id, kv.review_state, kv.lifecycle, kv.created_at AS version_created "
        "FROM knowledge k JOIN knowledge_version kv ON kv.id=k.current_version_id "
        "WHERE k.archived_at IS NULL ORDER BY k.created_at DESC LIMIT ?", (limit,)
    ).fetchall()
    return [{
        "knowledge_id": row["id"], "title": row["title"], "space": row["space"],
        "confidentiality": row["confidentiality"], "review_state": row["review_state"],
        "lifecycle": row["lifecycle"], "version_id": row["version_id"], "created_at": row["version_created"],
    } for row in rows]


def _review_parts(note: str | None) -> tuple[str | None, str | None]:
    """Trennt die frueher uebliche Klarnamen-Zeile von der eigentlichen Notiz."""
    text = str(note or "").strip()
    match = re.match(r"^Pruefperson:\s*(.+?)(?:\r?\n|$)", text)
    if match:
        return match.group(1).strip() or None, text[match.end():].strip() or None
    return None, text or None


def _review_payload(row) -> dict:
    legacy_name, note = _review_parts(row["note"])
    return {
        "reviewer": row["reviewer"],
        "reviewerName": legacy_name or row["reviewer"],
        "legacyReviewerName": legacy_name,
        "decision": row["decision"],
        "note": note,
        "decidedAt": row["decided_at"],
        "basisHash": row["basis_hash"],
        "invalidatedAt": row["invalidated_at"],
        "invalidatedByVersionId": row["invalidated_by_version_id"],
        "invalidatedReason": row["invalidated_reason"],
    }


def _version_rows(store, knowledge_id: str):
    versions = store.db.execute(
        "SELECT * FROM knowledge_version WHERE knowledge_id=? ORDER BY version_no", (knowledge_id,)
    ).fetchall()
    reviews = store.db.execute(
        "SELECT r.* FROM review r JOIN knowledge_version kv ON kv.id=r.knowledge_version_id "
        "WHERE kv.knowledge_id=? ORDER BY r.decided_at, r.id", (knowledge_id,)
    ).fetchall()
    events = store.db.execute(
        "SELECT type, entity_id, payload_json FROM event WHERE "
        "(entity_type='knowledge' AND entity_id=?) OR "
        "(entity_type='knowledge_version' AND entity_id IN "
        "(SELECT id FROM knowledge_version WHERE knowledge_id=?)) ORDER BY seq",
        (knowledge_id, knowledge_id),
    ).fetchall()
    return versions, reviews, events


def _change_reasons(events) -> dict[str, str]:
    reasons: dict[str, str] = {}
    for event in events:
        if event["type"] != "knowledge.revised":
            continue
        try:
            payload = json.loads(event["payload_json"] or "{}")
        except (TypeError, ValueError):
            continue
        version_id = payload.get("version_id") or event["entity_id"]
        reason = str(payload.get("reason") or "").strip()
        if version_id and reason:
            reasons[version_id] = reason
    return reasons


def _version_list(versions, reviews, events) -> list[dict]:
    reasons = _change_reasons(events)
    by_version: dict[str, list] = {}
    for review in reviews:
        by_version.setdefault(review["knowledge_version_id"], []).append(review)
    result = []
    for version in versions:
        result.append({
            "id": version["id"],
            "versionNo": version["version_no"],
            "createdAt": version["created_at"],
            "author": version["author"],
            "reviewState": version["review_state"],
            "lifecycle": version["lifecycle"],
            "basisHash": basis_hash(json.loads(version["basis_json"])),
            "contentHash": version["content_hash"],
            "supersedesVersionId": version["supersedes_version_id"],
            "changeReason": reasons.get(version["id"], ""),
            "reviews": [_review_payload(row) for row in by_version.get(version["id"], [])],
        })
    return result


def _history_list(versions, reviews, events) -> list[dict]:
    reasons = _change_reasons(events)
    version_no = {version["id"]: version["version_no"] for version in versions}
    successors = {version["supersedes_version_id"]: version for version in versions
                  if version["supersedes_version_id"]}
    items: list[tuple[str, int, dict]] = []
    order = 0
    for version in versions:
        reason = reasons.get(version["id"], "")
        if not reason:
            reason = "Erste Fassung angelegt" if version["version_no"] == 1 else "Neue Fassung angelegt"
        order += 1
        items.append((version["created_at"], order, {
            "type": "version",
            "at": version["created_at"],
            "versionId": version["id"],
            "versionNo": version["version_no"],
            "reviewState": version["review_state"],
            "actor": version["author"],
            "reason": reason,
        }))
    for review in reviews:
        order += 1
        payload = _review_payload(review)
        items.append((review["decided_at"], order, {
            "type": payload["decision"],
            "at": review["decided_at"],
            "versionId": review["knowledge_version_id"],
            "versionNo": version_no.get(review["knowledge_version_id"]),
            "reviewer": payload["reviewer"],
            "reviewerName": payload["reviewerName"],
            "legacyReviewerName": payload["legacyReviewerName"],
            "note": payload["note"],
            "basisHash": payload["basisHash"],
        }))
        successor = successors.get(review["knowledge_version_id"])
        if review["decision"] == "confirmed" and successor:
            order += 1
            items.append((successor["created_at"], order, {
                "type": "confirmation_superseded",
                "at": successor["created_at"],
                "versionId": review["knowledge_version_id"],
                "versionNo": version_no.get(review["knowledge_version_id"]),
                "reviewer": payload["reviewer"],
                "reason": f"Neue Fassung {successor['version_no']} ersetzt die bestätigte Fassung.",
                "newVersionId": successor["id"],
                "newVersionNo": successor["version_no"],
            }))
        if review["invalidated_at"]:
            order += 1
            items.append((review["invalidated_at"], order, {
                "type": "confirmation_superseded",
                "at": review["invalidated_at"],
                "versionId": review["knowledge_version_id"],
                "versionNo": version_no.get(review["knowledge_version_id"]),
                "reviewer": payload["reviewer"],
                "reason": review["invalidated_reason"] or "Belegbasis geändert",
            }))
    items.sort(key=lambda item: (item[0] or "", item[1]))
    return [item[2] for item in items]


def note_detail(store, knowledge_id: str, config: dict, principal: str | None = None) -> dict:
    row = store.db.execute("SELECT * FROM knowledge WHERE id=?", (knowledge_id,)).fetchone()
    if row is None:
        raise WbError(f"Wissen {knowledge_id} nicht gefunden.", "knowledge_missing", 2)
    principal = principal or store.meta("actor", "owner")
    access = acl.knowledge_access(store, row, principal, config)
    if not access["allowed"]:
        raise WbError("Zugriff verweigert: " + "; ".join(access["reasons"]), "knowledge_denied", 3)
    version = store.db.execute("SELECT * FROM knowledge_version WHERE id=?", (row["current_version_id"],)).fetchone()
    body = store.read_blob(version["content_hash"]).decode("utf-8", "strict") if version else None
    reviews = store.db.execute(
        "SELECT reviewer,decision,note,decided_at,basis_hash,invalidated_at,invalidated_by_version_id,invalidated_reason "
        "FROM review WHERE knowledge_version_id=? ORDER BY decided_at",
        (version["id"],),
    ).fetchall() if version else []
    provenance = store.db.execute(
        "SELECT p.relation, p.evidence_version_id, p.note, v.item_id, v.content_hash, i.display_path "
        "FROM provenance p LEFT JOIN version v ON v.id=p.evidence_version_id "
        "LEFT JOIN item i ON i.id=v.item_id WHERE p.knowledge_version_id=? ORDER BY p.created_at",
        (version["id"],),
    ).fetchall() if version else []
    version_rows, all_reviews, events = _version_rows(store, knowledge_id)
    return {
        "knowledge": dict(row),
        "version": dict(version) if version else None,
        "basis_hash": basis_hash(json.loads(version["basis_json"])) if version else None,
        "body": body,
        "access": access,
        "reviews": [dict(item) for item in reviews],
        "provenance": [dict(item) for item in provenance],
        "versions": _version_list(version_rows, all_reviews, events),
        "history": _history_list(version_rows, all_reviews, events),
    }


def version_detail(store, config: dict, version_id: str, principal: str | None = None) -> dict:
    """Eine einzelne Wissensfassung samt Text und Entscheidungen lesen."""
    version = store.db.execute("SELECT * FROM knowledge_version WHERE id=?", (version_id,)).fetchone()
    if version is None:
        raise WbError(f"Wissensfassung {version_id} nicht gefunden.", "knowledge_version_missing", 2)
    knowledge = store.db.execute("SELECT * FROM knowledge WHERE id=?", (version["knowledge_id"],)).fetchone()
    principal = principal or store.meta("actor", "owner")
    access = acl.knowledge_access(store, knowledge, principal, config)
    if not access["allowed"]:
        raise WbError("Zugriff verweigert: " + "; ".join(access["reasons"]), "knowledge_denied", 3)
    body = store.read_blob(version["content_hash"]).decode("utf-8", "strict")
    reviews = store.db.execute(
        "SELECT reviewer,decision,note,decided_at,basis_hash,invalidated_at,invalidated_by_version_id,"
        "invalidated_reason FROM review WHERE knowledge_version_id=? ORDER BY decided_at, id",
        (version_id,),
    ).fetchall()
    provenance = store.db.execute(
        "SELECT p.relation, p.evidence_version_id, p.note, v.item_id, i.display_path "
        "FROM provenance p LEFT JOIN version v ON v.id=p.evidence_version_id "
        "LEFT JOIN item i ON i.id=v.item_id WHERE p.knowledge_version_id=? ORDER BY p.created_at",
        (version_id,),
    ).fetchall()
    review_rows = []
    for item in reviews:
        legacy_name, note = _review_parts(item["note"])
        review_rows.append({
            **dict(item),
            "reviewer_name": legacy_name or item["reviewer"],
            "legacy_reviewer_name": legacy_name,
            "note_text": note,
        })
    return {
        "knowledge": dict(knowledge),
        "version": dict(version),
        "basis_hash": basis_hash(json.loads(version["basis_json"])),
        "body": body,
        "access": access,
        "reviews": review_rows,
        "provenance": [dict(item) for item in provenance],
        "is_current": knowledge["current_version_id"] == version_id,
    }


def ocr_version(store, config: dict, version_id: str) -> dict:
    """OCR als eigener Verarbeitungsschritt fuer ausstehende PDF-Seiten."""
    store.require_writable()
    version = store.db.execute("SELECT * FROM version WHERE id=?", (version_id,)).fetchone()
    if version is None:
        raise WbError(f"Fassung {version_id} nicht gefunden.", "version_missing", 2)
    item = store.db.execute("SELECT * FROM item WHERE id=?", (version["item_id"],)).fetchone()
    source = store.db.execute("SELECT * FROM source WHERE id=?", (item["source_id"],)).fetchone()
    binding = binding_for(config, item["source_id"])
    locator = binding.get("locator") if binding else None
    if not locator:
        raise WbError("Keine lokale Bindung fuer diese Quelle.", "source_binding", 2)
    access = acl.source_access(store, source, store.meta("actor", "owner"), locator)
    if not access["allowed"]:
        raise WbError("Quelle nicht zugaenglich: " + "; ".join(access["reasons"]), "ocr_denied", 3)
    path = Path(locator) / item["display_path"].replace("/", os.sep)
    if not path.exists():
        raise WbError("Originaldatei ist nicht mehr vorhanden.", "ocr_missing", 4)
    extraction = store.db.execute(
        "SELECT * FROM extraction WHERE version_id=? AND is_current=1", (version["id"],)
    ).fetchone()
    if extraction is None or "pages_json" not in extraction.keys() or not extraction["pages_json"]:
        raise WbError("Diese Fassung hat keine Seiteninformationen (kein PDF).", "ocr_not_pdf", 2)
    try:
        pages = json.loads(extraction["pages_json"])
    except ValueError as exc:
        raise WbError("Seiteninformationen sind nicht lesbar.", "ocr_not_pdf", 2) from exc
    if not isinstance(pages, list) or not pages:
        raise WbError("Diese Fassung hat keine Seiteninformationen (kein PDF).", "ocr_not_pdf", 2)
    pending = [page["page"] for page in pages if page.get("chars", 0) < 40 and not page.get("ocr", False)]
    if not pending:
        raise WbError("Keine ausstehenden Seiten fuer OCR.", "ocr_none", 2)
    from .extract import extract_pdf_ocr, repack_pdf_pages
    try:
        result = extract_pdf_ocr(path, pending)
    except Exception as exc:
        raise WbError(f"OCR fehlgeschlagen: {exc}", "ocr_failed", 4) from exc
    if not result.get("pages"):
        raise WbError("OCR lieferte keine Seiten.", "ocr_failed", 4)
    original_text = store.read_blob(extraction["text_hash"]).decode("utf-8", "strict") if extraction["text_hash"] else ""
    page_texts = {page["page"]: original_text[page["start"]:page["end"]] for page in pages}
    ocr_flags = {page["page"]: bool(page.get("ocr", False)) for page in pages}
    ocr_errors = []
    text_pages = []
    empty_pages = []
    for page in result["pages"]:
        number = page.get("page")
        text = str(page.get("text", ""))
        if page.get("error"):
            ocr_errors.append({"page": number, "error": page["error"]})
        if text.strip():
            page_texts[number] = text
            ocr_flags[number] = True
            text_pages.append(number)
        elif number in pending:
            empty_pages.append(number)
    skipped_limit = [int(number) for number in result.get("skipped_limit", [])]
    rebuilt = repack_pdf_pages([{"page": number, "text": page_texts[number], "ocr": ocr_flags[number]}
                                for number in sorted(page_texts)])
    reason = ("OCR ausgefuehrt auf Seiten " + (", ".join(str(number) for number in text_pages) if text_pages else "keiner")
              + "; Erkennungsunsicherheit und Layoutgrenzen moeglich")
    if empty_pages:
        reason += "; ohne erkannten Text: " + ", ".join(str(number) for number in empty_pages)
    if skipped_limit:
        reason += ("; OCR-Limit pro Lauf erreicht, ausstehend: "
                   + ", ".join(str(number) for number in skipped_limit))
    if ocr_errors:
        reason += "; Fehler auf Seiten: " + ", ".join(str(item["page"]) for item in ocr_errors)
    new_hash = store.put_blob(rebuilt["text"].encode("utf-8", "strict"), "text/plain; charset=utf-8") if rebuilt["text"] else None
    now = utc_now()
    new_id = "ext-" + uuid.uuid4().hex
    with store.transaction():
        store.db.execute("UPDATE extraction SET is_current=0 WHERE version_id=? AND is_current=1", (version["id"],))
        store.db.execute(
            "INSERT INTO extraction(id,version_id,extractor,extractor_version,status,reason,text_hash,created_at,is_current,pages_json) "
            "VALUES(?,?,?,?,?,?,?,?,1,?)",
            (new_id, version["id"], "pdf-ocr", "1", "partial", reason, new_hash, now,
             json.dumps(rebuilt["pages"], ensure_ascii=False, sort_keys=True)),
        )
        store.event("extraction.ocr", "version", version["id"],
                    {"pages": pending, "errors": ocr_errors, "extraction_id": new_id})
    return {"version_id": version["id"], "extraction_id": new_id, "status": "partial", "reason": reason,
            "pages": rebuilt["pages"], "requested_pages": pending, "ocr_pages": text_pages,
            "skipped_limit": skipped_limit, "empty_pages": empty_pages, "errors": ocr_errors}


def basis_hash(basis: list) -> str:
    return hashlib.sha256(json.dumps(basis, ensure_ascii=False, sort_keys=True).encode("utf-8")).hexdigest()


def add_claim(store, config: dict, kind: str, title: str, body_path: str,
              basis_versions: list[str], author: str | None = None) -> dict:
    """Abgeleitetes Wissen mit Pflicht-Belegkanten an konkrete Fassungen."""
    store.require_writable()
    if kind not in ("claim", "summary", "decision", "register_entry"):
        raise WbError("Belegpflichtige Wissensart erwartet (claim, summary, decision, register_entry).", "knowledge_kind")
    if not title.strip():
        raise WbError("Titel fehlt.", "knowledge_title")
    if not basis_versions:
        raise WbError("Mindestens eine Belegfassung angeben.", "knowledge_basis")
    body_file = Path(body_path).expanduser()
    if not body_file.exists():
        raise WbError(f"Wissensdatei nicht gefunden: {body_file}", "knowledge_body")
    body = body_file.read_text(encoding="utf-8", errors="strict")
    author = author or store.meta("actor", "owner")
    basis = []
    spaces = []
    confidences = []
    for version_identifier in basis_versions:
        version = store.db.execute("SELECT * FROM version WHERE id=?", (version_identifier,)).fetchone()
        if version is None:
            raise WbError(f"Belegfassung nicht gefunden: {version_identifier}", "evidence_missing", 2)
        item = store.db.execute("SELECT * FROM item WHERE id=?", (version["item_id"],)).fetchone()
        source = store.db.execute("SELECT * FROM source WHERE id=?", (item["source_id"],)).fetchone()
        binding = binding_for(config, item["source_id"])
        access = acl.source_access(store, source, store.meta("actor", "owner"),
                                   binding.get("locator") if binding else None)
        if not access["allowed"]:
            raise WbError("Beleg nicht zugänglich: " + "; ".join(access["reasons"]), "evidence_denied", 3)
        extraction = store.db.execute(
            "SELECT * FROM extraction WHERE version_id=? AND is_current=1", (version["id"],)
        ).fetchone()
        if extraction is None:
            raise WbError(f"Keine aktuelle Extraktion für {version_identifier}.", "evidence_extraction", 2)
        spaces.append(source["space"])
        confidences.append(source["confidentiality"])
        basis.append({
            "type": "version", "id": version["id"], "hash": version["content_hash"],
            "extraction_id": extraction["id"], "item_id": item["id"], "source_id": source["id"],
        })
    effective_space = "mixed" if "business" in spaces and "private" in spaces else spaces[0]
    effective_confidentiality = acl.max_confidentiality(confidences)
    content_hash = store.put_blob(body.encode("utf-8", "strict"), "text/markdown; charset=utf-8")
    knowledge_id = "knw-" + uuid.uuid4().hex
    version_id = "knv-" + uuid.uuid4().hex
    now = utc_now()
    basis_json = json.dumps(basis, ensure_ascii=False, sort_keys=True)
    with store.transaction():
        store.db.execute(
            "INSERT INTO knowledge(id,kind,title,space,confidentiality,canonical,created_by,created_at,current_version_id) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            (knowledge_id, kind, title.strip(), effective_space, effective_confidentiality, 1, author, now, version_id),
        )
        store.db.execute(
            "INSERT INTO knowledge_version(id,knowledge_id,version_no,content_hash,author,created_at,lifecycle,review_state,basis_json,effective_space,effective_confidentiality) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (version_id, knowledge_id, 1, content_hash, author, now, "draft", "needs_review",
             basis_json, effective_space, effective_confidentiality),
        )
        for entry in basis:
            store.db.execute(
                "INSERT INTO provenance(id,knowledge_version_id,relation,evidence_version_id,note,created_at) "
                "VALUES(?,?,?,?,?,?)",
                ("prv-" + uuid.uuid4().hex, version_id, "derived_from", entry["id"],
                 "Belegfassung bei Erstellung", now),
            )
        store.event("knowledge.created", "knowledge", knowledge_id,
                    {"kind": kind, "space": effective_space, "version_id": version_id,
                     "basis": [entry["id"] for entry in basis]})
    return {"knowledge_id": knowledge_id, "knowledge_version_id": version_id, "space": effective_space,
            "confidentiality": effective_confidentiality, "review_state": "needs_review",
            "basis_hash": basis_hash(basis), "basis": basis}


def revise(store, knowledge_id: str, body_path: str, author: str | None = None,
           reason: str | None = None, expected_version_id: str | None = None,
           expected_basis_hash: str | None = None, basis_versions: list[str] | None = None,
           config: dict | None = None) -> dict:
    """Legt eine neue Fassung an, ohne die alte Fassung oder ihre Reviews zu aendern."""
    store.require_writable()
    knowledge = store.db.execute("SELECT * FROM knowledge WHERE id=?", (knowledge_id,)).fetchone()
    if knowledge is None:
        raise WbError(f"Wissen {knowledge_id} nicht gefunden.", "knowledge_missing", 2)
    current = store.db.execute(
        "SELECT * FROM knowledge_version WHERE id=?", (knowledge["current_version_id"],)
    ).fetchone()
    if current is None:
        raise WbError("Aktuelle Wissensfassung nicht gefunden.", "knowledge_version_missing", 2)
    if expected_version_id and current["id"] != expected_version_id:
        raise WbError("Die Wissensfassung ist nicht mehr aktuell; Seite neu laden.", "knowledge_conflict", 6)
    basis = json.loads(current["basis_json"])
    current_basis = basis_hash(basis)
    if expected_basis_hash and expected_basis_hash != current_basis:
        raise WbError("Die Belegbasis hat sich geändert; Seite neu prüfen.", "review_conflict", 6)
    if current["review_state"] == "confirmation_stale":
        raise WbError("Die Bestätigung ist überholt; die Seite muss mit der neuen Belegbasis neu erstellt werden.",
                      "knowledge_stale", 6)
    basis_changed = False
    effective_space = current["effective_space"]
    effective_confidentiality = current["effective_confidentiality"]
    if basis_versions:
        basis = []
        spaces = []
        confidences = []
        for version_identifier in basis_versions:
            version = store.db.execute("SELECT * FROM version WHERE id=?", (version_identifier,)).fetchone()
            if version is None:
                raise WbError(f"Belegfassung nicht gefunden: {version_identifier}", "evidence_missing", 2)
            item = store.db.execute("SELECT * FROM item WHERE id=?", (version["item_id"],)).fetchone()
            source = store.db.execute("SELECT * FROM source WHERE id=?", (item["source_id"],)).fetchone()
            if config:
                binding = binding_for(config, item["source_id"])
                access = acl.source_access(store, source, store.meta("actor", "owner"),
                                           binding.get("locator") if binding else None)
                if not access["allowed"]:
                    raise WbError("Beleg nicht zugänglich: " + "; ".join(access["reasons"]), "evidence_denied", 3)
            extraction = store.db.execute(
                "SELECT * FROM extraction WHERE version_id=? AND is_current=1", (version["id"],)
            ).fetchone()
            if extraction is None:
                raise WbError(f"Keine aktuelle Extraktion für {version_identifier}.", "evidence_extraction", 2)
            spaces.append(source["space"])
            confidences.append(source["confidentiality"])
            basis.append({
                "type": "version", "id": version["id"], "hash": version["content_hash"],
                "extraction_id": extraction["id"], "item_id": item["id"], "source_id": source["id"],
            })
        effective_space = "mixed" if "business" in spaces and "private" in spaces else spaces[0]
        effective_confidentiality = acl.max_confidentiality(confidences)
        basis_changed = True
    basis_json = json.dumps(basis, ensure_ascii=False, sort_keys=True)
    new_basis_hash = basis_hash(basis)
    body_file = Path(body_path).expanduser()
    if not body_file.exists():
        raise WbError(f"Wissensdatei nicht gefunden: {body_file}", "knowledge_body")
    body = body_file.read_text(encoding="utf-8", errors="strict")
    content_hash = store.put_blob(body.encode("utf-8", "strict"), "text/markdown; charset=utf-8")
    if content_hash == current["content_hash"] and not basis_changed:
        raise WbError("Der Text ist unverändert; keine neue Fassung angelegt.", "knowledge_unchanged")
    author = author or store.meta("actor", "owner")
    change_reason = (reason or "").strip() or "Wissensseite überarbeitet"
    version_id = "knv-" + uuid.uuid4().hex
    version_no = store.db.execute(
        "SELECT COALESCE(MAX(version_no), 0) + 1 FROM knowledge_version WHERE knowledge_id=?", (knowledge_id,)
    ).fetchone()[0]
    now = utc_now()
    with store.transaction():
        store.db.execute(
            "INSERT INTO knowledge_version(id,knowledge_id,version_no,content_hash,author,created_at,lifecycle,"
            "review_state,basis_json,effective_space,effective_confidentiality,supersedes_version_id) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            (version_id, knowledge_id, version_no, content_hash, author, now, "draft", "needs_review",
             basis_json, effective_space, effective_confidentiality, current["id"]),
        )
        if basis_changed:
            for entry in basis:
                store.db.execute(
                    "INSERT INTO provenance(id,knowledge_version_id,relation,evidence_version_id,note,created_at) "
                    "VALUES(?,?,?,?,?,?)",
                    ("prv-" + uuid.uuid4().hex, version_id, "derived_from", entry["id"],
                     "Belegfassung bei Überarbeitung", now),
                )
        else:
            for row in store.db.execute(
                "SELECT relation,evidence_version_id,evidence_citation_id,target_knowledge_version_id,note "
                "FROM provenance WHERE knowledge_version_id=? ORDER BY created_at", (current["id"],)
            ).fetchall():
                store.db.execute(
                    "INSERT INTO provenance(id,knowledge_version_id,relation,evidence_version_id,evidence_citation_id,"
                    "target_knowledge_version_id,note,created_at) VALUES(?,?,?,?,?,?,?,?)",
                    ("prv-" + uuid.uuid4().hex, version_id, row["relation"], row["evidence_version_id"],
                     row["evidence_citation_id"], row["target_knowledge_version_id"],
                     "Belegfassung bei Überarbeitung" if row["evidence_version_id"] else row["note"], now),
                )
        store.db.execute("UPDATE knowledge SET current_version_id=?, space=?, confidentiality=? WHERE id=?",
                         (version_id, effective_space, effective_confidentiality, knowledge_id))
        store.event("knowledge.revised", "knowledge", knowledge_id, {
            "version_id": version_id,
            "previous_version_id": current["id"],
            "version_no": version_no,
            "reason": change_reason,
            "basis_hash": new_basis_hash,
        })
    return {
        "knowledge_id": knowledge_id,
        "knowledge_version_id": version_id,
        "previous_version_id": current["id"],
        "version_no": version_no,
        "review_state": "needs_review",
        "basis_hash": new_basis_hash,
        "space": effective_space,
        "confidentiality": effective_confidentiality,
        "reason": change_reason,
    }


def invalidate_evidence(store, superseded_version_id: str, new_version_id: str) -> list[dict]:
    """Markiert abhängiges Wissen und Bestätigungen als prüfbedürftig.

    Wird beim Import einer neuen Fassung aufgerufen. Historische Fassungen und
    deren Text bleiben unverändert abrufbar; nur der Prüfstatus ändert sich.
    """
    rows = store.db.execute(
        "SELECT DISTINCT kv.id AS knowledge_version_id, kv.knowledge_id, kv.review_state, k.title "
        "FROM provenance p JOIN knowledge_version kv ON kv.id=p.knowledge_version_id "
        "JOIN knowledge k ON k.id=kv.knowledge_id WHERE p.evidence_version_id=?",
        (superseded_version_id,),
    ).fetchall()
    affected = []
    for row in rows:
        new_state = "confirmation_stale" if row["review_state"] == "confirmed" else "needs_review"
        if row["review_state"] == new_state:
            continue
        store.db.execute("UPDATE knowledge_version SET review_state=? WHERE id=?",
                         (new_state, row["knowledge_version_id"]))
        if row["review_state"] == "confirmed":
            store.db.execute(
                "UPDATE review SET invalidated_by_version_id=?, invalidated_at=?, invalidated_reason=? "
                "WHERE id=(SELECT id FROM review WHERE knowledge_version_id=? AND decision='confirmed' "
                "ORDER BY decided_at DESC LIMIT 1)",
                (new_version_id, utc_now(), f"Belegfassung {superseded_version_id} durch {new_version_id} abgelöst",
                 row["knowledge_version_id"]),
            )
        store.event("knowledge.needs_recheck", "knowledge_version", row["knowledge_version_id"],
                    {"reason": "evidence_superseded", "superseded_version_id": superseded_version_id,
                     "new_version_id": new_version_id, "review_state": new_state})
        affected.append({"knowledge_version_id": row["knowledge_version_id"],
                         "knowledge_id": row["knowledge_id"], "title": row["title"],
                         "review_state": new_state})
    return affected


def evidence(store, config: dict, version_id: str, principal: str | None = None) -> dict:
    """Historische Fassung samt extrahiertem Text und Seitenbezug abrufen."""
    version = store.db.execute("SELECT * FROM version WHERE id=?", (version_id,)).fetchone()
    if version is None:
        raise WbError(f"Fassung {version_id} nicht gefunden.", "version_missing", 2)
    item = store.db.execute("SELECT * FROM item WHERE id=?", (version["item_id"],)).fetchone()
    source = store.db.execute("SELECT * FROM source WHERE id=?", (item["source_id"],)).fetchone()
    principal = principal or store.meta("actor", "owner")
    binding = binding_for(config, item["source_id"])
    access = acl.source_access(store, source, principal, binding.get("locator") if binding else None)
    if not access["allowed"]:
        raise WbError("Beleg nicht zugänglich: " + "; ".join(access["reasons"]), "evidence_denied", 3)
    extraction = store.db.execute(
        "SELECT * FROM extraction WHERE version_id=? AND is_current=1", (version["id"],)
    ).fetchone()
    if extraction is None:
        raise WbError("Keine Extraktion für diese Fassung.", "evidence_extraction", 2)
    text = store.read_blob(extraction["text_hash"]).decode("utf-8", "strict") if extraction["text_hash"] else ""
    pages = []
    if "pages_json" in extraction.keys() and extraction["pages_json"]:
        try:
            pages = json.loads(extraction["pages_json"])
        except ValueError:
            pages = []
    latest = store.db.execute("SELECT id FROM version WHERE item_id=? ORDER BY seq_no DESC LIMIT 1",
                              (item["id"],)).fetchone()[0]
    superseded_by = store.db.execute("SELECT id FROM version WHERE supersedes_version_id=? ORDER BY seq_no LIMIT 1",
                                     (version["id"],)).fetchone()
    links = store.db.execute(
        "SELECT DISTINCT kv.id AS knowledge_version_id, kv.review_state, k.id AS knowledge_id, k.title "
        "FROM provenance p JOIN knowledge_version kv ON kv.id=p.knowledge_version_id "
        "JOIN knowledge k ON k.id=kv.knowledge_id WHERE p.evidence_version_id=?",
        (version["id"],),
    ).fetchall()
    return {
        "version": dict(version),
        "item": {"item_id": item["id"], "source_id": item["source_id"], "display_path": item["display_path"],
                 "space": source["space"], "source_name": source["name"]},
        "is_current": version["id"] == latest,
        "superseded_by": superseded_by["id"] if superseded_by else None,
        "extraction": {"id": extraction["id"], "status": extraction["status"], "extractor": extraction["extractor"],
                       "extractor_version": extraction["extractor_version"], "reason": extraction["reason"]},
        "pages": pages,
        "text": text,
        "access": access,
        "knowledge_links": [dict(row) for row in links],
    }


def confirm(store, knowledge_version_id: str, reviewer: str | None = None, note: str | None = None,
            expected_basis: str | None = None) -> dict:
    store.require_writable()
    version = store.db.execute("SELECT * FROM knowledge_version WHERE id=?", (knowledge_version_id,)).fetchone()
    if version is None:
        raise WbError(f"Wissensfassung {knowledge_version_id} nicht gefunden.", "knowledge_version_missing", 2)
    knowledge = store.db.execute("SELECT * FROM knowledge WHERE id=?", (version["knowledge_id"],)).fetchone()
    reviewer = reviewer or store.meta("actor", "owner")
    if not acl.has_action(store, reviewer, "review", "knowledge", knowledge["id"]):
        raise WbError(f"{reviewer} hat kein Bestaetigungsrecht.", "review_denied", 3)
    basis = json.loads(version["basis_json"])
    current_hash = basis_hash(basis)
    if expected_basis and expected_basis != current_hash:
        raise WbError("Belegbasis hat sich geaendert; Bestaetigung abgelehnt.", "review_conflict", 6)
    now = utc_now()
    with store.transaction():
        store.db.execute(
            "INSERT INTO review(id,knowledge_version_id,reviewer,decision,note,decided_at,basis_hash,basis_json) "
            "VALUES(?,?,?,?,?,?,?,?)",
            ("rev-" + uuid.uuid4().hex, knowledge_version_id, reviewer, "confirmed", note, now, current_hash,
             json.dumps(basis, ensure_ascii=False, sort_keys=True)),
        )
        store.db.execute("UPDATE knowledge_version SET review_state='confirmed', lifecycle='active' WHERE id=?",
                         (knowledge_version_id,))
        store.event("review.confirmed", "knowledge_version", knowledge_version_id,
                    {"reviewer": reviewer, "basis_hash": current_hash, "note": note})
    return {"knowledge_version_id": knowledge_version_id, "review_state": "confirmed", "basis_hash": current_hash,
            "reviewer": reviewer, "decided_at": now}


def reject(store, knowledge_version_id: str, reviewer: str | None = None, note: str | None = None) -> dict:
    store.require_writable()
    version = store.db.execute("SELECT * FROM knowledge_version WHERE id=?", (knowledge_version_id,)).fetchone()
    if version is None:
        raise WbError("Wissensfassung nicht gefunden.", "knowledge_version_missing", 2)
    knowledge = store.db.execute("SELECT * FROM knowledge WHERE id=?", (version["knowledge_id"],)).fetchone()
    reviewer = reviewer or store.meta("actor", "owner")
    if not acl.has_action(store, reviewer, "review", "knowledge", knowledge["id"]):
        raise WbError(f"{reviewer} hat kein Bestaetigungsrecht.", "review_denied", 3)
    basis = json.loads(version["basis_json"])
    now = utc_now()
    with store.transaction():
        store.db.execute(
            "INSERT INTO review(id,knowledge_version_id,reviewer,decision,note,decided_at,basis_hash,basis_json) VALUES(?,?,?,?,?,?,?,?)",
            ("rev-" + uuid.uuid4().hex, knowledge_version_id, reviewer, "rejected", note, now, basis_hash(basis),
             json.dumps(basis, ensure_ascii=False, sort_keys=True)),
        )
        store.db.execute("UPDATE knowledge_version SET review_state='rejected' WHERE id=?", (knowledge_version_id,))
        store.event("review.rejected", "knowledge_version", knowledge_version_id, {"reviewer": reviewer, "note": note})
    return {"knowledge_version_id": knowledge_version_id, "review_state": "rejected", "reviewer": reviewer}


def stats(store) -> dict:
    def one(sql: str, params=()):
        return store.db.execute(sql, params).fetchone()[0]

    by_space = {}
    for row in store.db.execute(
        "SELECT s.space, count(*) AS items, sum(v.size) AS bytes FROM item i JOIN source s ON s.id=i.source_id "
        "LEFT JOIN version v ON v.id=(SELECT id FROM version WHERE item_id=i.id ORDER BY seq_no DESC LIMIT 1) "
        "WHERE i.removed_at IS NULL GROUP BY s.space"
    ).fetchall():
        by_space[row["space"]] = {"items": row["items"], "bytes": row["bytes"] or 0}
    return {
        "sources": one("SELECT count(*) FROM source"),
        "items": one("SELECT count(*) FROM item WHERE removed_at IS NULL"),
        "versions": one("SELECT count(*) FROM version"),
        "extractions_full": one("SELECT count(*) FROM extraction WHERE is_current=1 AND status='full'"),
        "extractions_partial": one("SELECT count(*) FROM extraction WHERE is_current=1 AND status='partial'"),
        "extractions_failed": one("SELECT count(*) FROM extraction WHERE is_current=1 AND status='failed'"),
        "extractions_unsupported": one("SELECT count(*) FROM extraction WHERE is_current=1 AND status='unsupported'"),
        "text_blobs": one("SELECT count(*) FROM blob"),
        "notes": one("SELECT count(*) FROM knowledge WHERE archived_at IS NULL"),
        "reviews": one("SELECT count(*) FROM review"),
        "events": one("SELECT count(*) FROM event"),
        "by_space": by_space,
    }
