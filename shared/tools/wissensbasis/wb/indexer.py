"""FTS5-Index: jederzeit loeschbar und aus Ledger + Text-Blobs neu baubar."""
from __future__ import annotations

import bisect
import json
import os
import re
import shutil
import sqlite3
import time
import uuid
from pathlib import Path

from . import acl
from .config import binding_for
from .util import WbError, parse_terms, utc_now

CHUNK_SIZE = 1200
CHUNK_OVERLAP = 200
INDEX_SCHEMA_VERSION = "2"


def _heading_positions(text: str) -> tuple[list[int], list[str]]:
    starts: list[int] = []
    titles: list[str] = []
    for match in re.finditer(r"(?m)^#{1,6}\s+(.+)$", text):
        starts.append(match.start())
        titles.append(match.group(1).strip())
    return starts, titles


def _chunks(text: str):
    if not text:
        return
    starts, titles = _heading_positions(text)
    length = len(text)
    start = 0
    while start < length:
        end = min(length, start + CHUNK_SIZE)
        if end < length:
            boundary = text.rfind(" ", start + CHUNK_SIZE - 120, end)
            if boundary > start:
                end = boundary
        index = bisect.bisect_right(starts, start) - 1
        heading = titles[index] if index >= 0 else ""
        yield start, text[start:end], heading
        if end >= length:
            break
        start = max(start + 1, end - CHUNK_OVERLAP)


def index_path(store) -> Path:
    return store.root / "index" / "search.sqlite3"


def build_json_path(store) -> Path:
    return store.root / "index" / "build.json"


def index_status(store) -> dict:
    path = index_path(store)
    if not path.exists():
        return {"state": "missing", "path": str(path)}
    info = {"state": "current", "path": str(path), "size_bytes": path.stat().st_size}
    try:
        db = sqlite3.connect(str(path))
        try:
            row = db.execute("SELECT value FROM index_meta WHERE key='schema_version'").fetchone()
            info["schema_version"] = row[0] if row else None
            if row is None or row[0] != INDEX_SCHEMA_VERSION:
                info["state"] = "stale"
        finally:
            db.close()
    except sqlite3.Error as exc:
        info["state"] = "unreadable"
        info["detail"] = str(exc)
    if build_json_path(store).exists():
        try:
            info.update(json.loads(build_json_path(store).read_text(encoding="utf-8")))
        except (OSError, ValueError):
            info["state"] = "unknown"
    return info


def _page_at(pages: list[dict], offset: int) -> int | None:
    if not pages:
        return None
    starts = [int(page.get("start", 0)) for page in pages]
    index = bisect.bisect_right(starts, offset) - 1
    return pages[max(0, index)].get("page")


def _page_for(pages: list[dict], offset: int) -> int | None:
    return _page_at(pages, offset)


def rebuild(store) -> dict:
    started = time.time()
    index_dir = store.root / "index"
    index_dir.mkdir(parents=True, exist_ok=True)
    temp = index_dir / f"search.build-{uuid.uuid4().hex}.sqlite3"
    if temp.exists():
        temp.unlink()
    db = sqlite3.connect(str(temp))
    try:
        db.row_factory = sqlite3.Row
        db.executescript(
            """
            CREATE VIRTUAL TABLE chunk USING fts5(
              version_id UNINDEXED, item_id UNINDEXED, source_id UNINDEXED,
              space UNINDEXED, text_start UNINDEXED, page UNINDEXED, heading, text, tokenize='unicode61'
            );
            CREATE VIRTUAL TABLE knowledge_chunk USING fts5(
              knowledge_version_id UNINDEXED, knowledge_id UNINDEXED,
              space UNINDEXED, text_start UNINDEXED, title, text, tokenize='unicode61'
            );
            CREATE TABLE index_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """
        )
        versions = store.db.execute(
            """
            SELECT e.id AS extraction_id, e.text_hash, e.pages_json, v.id AS version_id, v.content_hash,
                   i.id AS item_id, i.display_path, s.id AS source_id, s.space, s.name AS source_name
            FROM extraction e
            JOIN version v ON v.id = e.version_id
            JOIN item i ON i.id = v.item_id
            JOIN source s ON s.id = i.source_id
            WHERE e.is_current = 1 AND e.text_hash IS NOT NULL AND e.status IN ('full','partial')
            ORDER BY s.id, i.external_id, v.seq_no
            """
        ).fetchall()
        for row in versions:
            text = store.read_blob(row["text_hash"]).decode("utf-8", "strict")
            pages = []
            if row["pages_json"]:
                try:
                    pages = json.loads(row["pages_json"])
                except ValueError:
                    pages = []
            for start, chunk, heading in _chunks(text):
                db.execute(
                    "INSERT INTO chunk(version_id,item_id,source_id,space,text_start,page,heading,text) "
                    "VALUES(?,?,?,?,?,?,?,?)",
                    (row["version_id"], row["item_id"], row["source_id"], row["space"], start,
                     _page_for(pages, start), heading, chunk),
                )
        knowledge = store.db.execute(
            """
            SELECT kv.id AS knowledge_version_id, k.id AS knowledge_id, k.title,
                   kv.effective_space AS space, kv.content_hash
            FROM knowledge_version kv JOIN knowledge k ON k.id = kv.knowledge_id
            WHERE k.archived_at IS NULL AND kv.id = k.current_version_id
            ORDER BY k.id
            """
        ).fetchall()
        for row in knowledge:
            text = store.read_blob(row["content_hash"]).decode("utf-8", "strict")
            for start, chunk, _heading in _chunks(text):
                db.execute(
                    "INSERT INTO knowledge_chunk(knowledge_version_id,knowledge_id,space,text_start,title,text) VALUES(?,?,?,?,?,?)",
                    (row["knowledge_version_id"], row["knowledge_id"], row["space"], start, row["title"], chunk),
                )
        build_id = "idx-" + uuid.uuid4().hex
        counts = {
            "versions": len(versions),
            "evidence_chunks": db.execute("SELECT count(*) FROM chunk").fetchone()[0],
            "knowledge_versions": len(knowledge),
            "knowledge_chunks": db.execute("SELECT count(*) FROM knowledge_chunk").fetchone()[0],
        }
        for key, value in {
            "build_id": build_id,
            "built_at": utc_now(),
            "schema_version": INDEX_SCHEMA_VERSION,
            **{key: str(value) for key, value in counts.items()},
        }.items():
            db.execute("INSERT INTO index_meta(key,value) VALUES(?,?)", (key, value))
        db.commit()
    finally:
        db.close()
    current = index_path(store)
    previous = index_dir / "search.previous.sqlite3"
    if current.exists():
        shutil.copy2(current, previous)
    os.replace(temp, current)
    info = {"build_id": build_id, "built_at": utc_now(), "elapsed_seconds": round(time.time() - started, 3),
            "index_bytes": current.stat().st_size, "schema_version": INDEX_SCHEMA_VERSION, **counts}
    from .util import atomic_write_text
    atomic_write_text(build_json_path(store), json.dumps(info, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    if not store.readonly:
        store.event("index.rebuilt", "index", build_id,
                    {"versions": len(versions), "knowledge_versions": len(knowledge), "chunks": counts["evidence_chunks"]})
    return info


def _fts_query(terms: list[str], any_term: bool) -> str:
    quoted = ['"' + term.replace('"', '""') + '"' for term in terms]
    return (" OR " if any_term else " AND ").join(quoted)


def _snippet(text: str, terms: list[str], start_offset: int) -> tuple[str, dict]:
    # Wichtig: Positionen im Originaltext bestimmen, nicht im casefold-Text.
    # casefold() kann die Laenge veraendern (z. B. ss fuer eszett) und wuerde
    # Zeichenstellen verschieben. re.search liefert die korrekte Originalstelle.
    best = None
    for term in terms:
        match = re.search(re.escape(term), text, re.IGNORECASE)
        if match and (best is None or match.start() < best[0]):
            best = (match.start(), match.end() - match.start())
    position, term_length = best if best else (0, 0)
    left = max(0, position - 140)
    right = min(len(text), position + term_length + 140)
    snippet = text[left:right]
    if left > 0:
        snippet = "…" + snippet
    if right < len(text):
        snippet = snippet + "…"
    citation = {"kind": "char", "start": start_offset + position, "end": start_offset + position + max(term_length, 1)}
    return snippet, citation


def _searchable_sources(store, config: dict, principal: str) -> dict:
    cache = {}
    for source_row in store.db.execute("SELECT * FROM source ORDER BY id").fetchall():
        binding = binding_for(config, source_row["id"])
        locator = binding.get("locator") if binding else None
        cache[source_row["id"]] = acl.source_access(store, source_row, principal, locator)
    return cache


def search(store, config: dict, query: str, limit: int = 50, any_term: bool = False,
           space: str | None = None, principal: str | None = None) -> dict:
    terms = parse_terms(query)
    if not terms:
        raise WbError("Leere Suchanfrage.", "query_empty")
    path = index_path(store)
    if not path.exists():
        raise WbError("Suchindex fehlt. 'wb index rebuild' ausfuehren.", "index_missing", 2)
    principal = principal or store.meta("actor", "owner")
    access = _searchable_sources(store, config, principal)
    db = sqlite3.connect(str(path))
    db.row_factory = sqlite3.Row
    try:
        meta_row = db.execute("SELECT value FROM index_meta WHERE key='schema_version'").fetchone()
        if meta_row is None or meta_row["value"] != INDEX_SCHEMA_VERSION:
            raise WbError("Suchindex hat ein aelteres Schema. 'wb index rebuild' ausfuehren.", "index_stale", 2)
        expression = _fts_query(terms, any_term)
        rows = db.execute(
            "SELECT version_id,item_id,source_id,space,text_start,page,heading,text,bm25(chunk) AS score "
            "FROM chunk WHERE chunk MATCH ? ORDER BY score LIMIT ?",
            (expression, max(limit * 4, 50)),
        ).fetchall()
        results = []
        filtered = 0
        for row in rows:
            access_state = access.get(row["source_id"])
            if not access_state or not access_state["allowed"]:
                filtered += 1
                continue
            if space and row["space"] != space:
                continue
            item = store.db.execute("SELECT * FROM item WHERE id=?", (row["item_id"],)).fetchone()
            version = store.db.execute("SELECT * FROM version WHERE id=?", (row["version_id"],)).fetchone()
            source = store.db.execute("SELECT * FROM source WHERE id=?", (row["source_id"],)).fetchone()
            extraction = store.db.execute(
                "SELECT * FROM extraction WHERE version_id=? AND is_current=1", (row["version_id"],)
            ).fetchone()
            snippet, citation = _snippet(row["text"], terms, row["text_start"])
            page = row["page"]
            if extraction is not None and "pages_json" in extraction.keys() and extraction["pages_json"]:
                try:
                    page = _page_at(json.loads(extraction["pages_json"]), citation["start"]) or page
                except ValueError:
                    page = row["page"]
            results.append({
                "type": "evidence",
                "source_id": row["source_id"],
                "source_name": source["name"],
                "space": row["space"],
                "confidentiality": source["confidentiality"],
                "item_id": row["item_id"],
                "version_id": row["version_id"],
                "display_path": item["display_path"],
                "content_hash": version["content_hash"],
                "heading": row["heading"],
                "page": page,
                "snippet": snippet,
                "citation": citation,
                "extraction_status": extraction["status"] if extraction else "unknown",
                "access_basis": access_state["basis"],
                "score": row["score"],
            })
            if len(results) >= limit:
                break
        knowledge_rows = db.execute(
            "SELECT knowledge_version_id,knowledge_id,space,text_start,title,text,bm25(knowledge_chunk) AS score "
            "FROM knowledge_chunk WHERE knowledge_chunk MATCH ? ORDER BY score LIMIT ?",
            (expression, max(limit * 2, 20)),
        ).fetchall()
        for row in knowledge_rows:
            knowledge = store.db.execute("SELECT * FROM knowledge WHERE id=?", (row["knowledge_id"],)).fetchone()
            version = store.db.execute("SELECT * FROM knowledge_version WHERE id=?", (row["knowledge_version_id"],)).fetchone()
            decision = acl.knowledge_access(store, knowledge, principal, config)
            if not decision["allowed"]:
                filtered += 1
                continue
            if space and row["space"] != space:
                continue
            snippet, citation = _snippet(row["text"], terms, row["text_start"])
            results.append({
                "type": "knowledge",
                "knowledge_id": row["knowledge_id"],
                "knowledge_version_id": row["knowledge_version_id"],
                "space": row["space"],
                "title": row["title"],
                "snippet": snippet,
                "citation": citation,
                "review_state": version["review_state"],
                "access_basis": decision["basis"],
                "score": row["score"],
            })
            if len(results) >= limit * 2:
                break
        results.sort(key=lambda entry: entry["score"])
        return {
            "query": query,
            "mode": "any" if any_term else "all",
            "results": results[:limit],
            "total_returned": min(len(results), limit),
            "filtered_by_access": filtered,
            "principal": principal,
        }
    finally:
        db.close()
