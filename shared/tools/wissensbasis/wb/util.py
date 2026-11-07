"""Gemeinsame Hilfsfunktionen für den Wissensbasis-Pilotkern (nur Standardbibliothek)."""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "wb/v1"


class WbError(Exception):
    """Erwartbarer Fehler mit stabilem Exit-Code und JSON-Code."""

    def __init__(self, message: str, code: str = "error", exit_code: int = 2, recoverable: bool = True):
        super().__init__(message)
        self.message = message
        self.code = code
        self.exit_code = exit_code
        self.recoverable = recoverable


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "strict")).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def short_id(prefix: str, *parts: str) -> str:
    payload = "\x00".join(parts).encode("utf-8", "strict")
    return prefix + hashlib.sha256(payload).hexdigest()[:24]


def item_id(source_id: str, external_id: str) -> str:
    return short_id("itm-", source_id, external_id)


def version_id(item: str, content_hash: str) -> str:
    return short_id("ver-", item, content_hash)


def binding_fingerprint(locator: str) -> str:
    normalized = locator.strip().replace("/", "\\").rstrip("\\").casefold()
    return hashlib.sha256(normalized.encode("utf-8", "strict")).hexdigest()


def normalize_external_id(relative: str) -> str:
    value = relative.replace("\\", "/")
    while value.startswith("./"):
        value = value[2:]
    return value.lstrip("/").casefold()


def is_within(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except (ValueError, OSError):
        return False


def atomic_write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(mode="wb", dir=path.parent, delete=False)
    tmp = Path(handle.name)
    try:
        with handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink(missing_ok=True)


def atomic_write_text(path: Path, text: str) -> None:
    atomic_write_bytes(path, text.encode("utf-8", "strict"))


def dump_json(value) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def envelope(ok: bool, data=None, warnings=None, error=None, meta=None) -> dict:
    return {
        "schema": SCHEMA,
        "ok": ok,
        "data": data,
        "warnings": warnings or [],
        "error": error,
        "meta": meta or {},
    }


def emit(payload: dict, as_json: bool) -> None:
    """JSON ist ASCII-sicher; die menschliche Ausgabe bleibt deutsch."""
    if as_json:
        text = json.dumps(payload, ensure_ascii=True, sort_keys=True)
    else:
        if payload["ok"]:
            text = _human(payload["data"])
        else:
            error = payload.get("error") or {}
            text = f"FEHLER {error.get('code')}: {error.get('message')}"
    try:
        sys.stdout.write(text + "\n")
        sys.stdout.flush()
    except UnicodeEncodeError:
        sys.stdout.buffer.write((text + "\n").encode("utf-8", "replace"))
        sys.stdout.buffer.flush()


def _human(data) -> str:
    if data is None:
        return "OK"
    if isinstance(data, str):
        return data
    return json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True)


def human_size(size: int) -> str:
    value = float(size)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024 or unit == "GB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024
    return f"{value:.1f} GB"


def safe_name(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-") or "unnamed"


def parse_terms(query: str, maximum: int = 12) -> list[str]:
    query = (query or "").strip()
    if len(query) > 300:
        raise WbError("Suchanfrage ist länger als 300 Zeichen.", "query_too_long")
    terms = []
    for term in re.split(r"\s+", query):
        if not term:
            continue
        if len(term) > 80:
            raise WbError("Ein Suchwort ist länger als 80 Zeichen.", "query_term_too_long")
        if term not in terms:
            terms.append(term)
    if len(terms) > maximum:
        raise WbError(f"Höchstens {maximum} Suchwörter pro Anfrage.", "query_too_many_terms")
    return terms
