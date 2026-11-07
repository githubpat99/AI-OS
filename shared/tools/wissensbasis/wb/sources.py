"""Quellenregister: stabile IDs, Herkunft, Bindungen, tatsaechlicher Zugriff."""
from __future__ import annotations

import json
import re
import uuid
from pathlib import Path

from . import acl
from .config import binding_for, save_config, set_binding
from .util import WbError, binding_fingerprint, utc_now

SOURCE_KINDS = {"git_repo", "folder", "mail_archive", "web", "cloud_export", "curated"}
SPACES = {"business", "private"}
CONFIDENTIALITY = {"public", "internal", "confidential", "restricted"}


def _validate_source_id(value: str) -> str:
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{2,63}", value or ""):
        raise WbError("Quellen-ID: 3 bis 64 Zeichen, klein, Ziffern und Bindestriche.", "source_id")
    return value


def add_source(store, config: dict, config_path: Path | None, values: dict) -> dict:
    store.require_writable()
    source_id = _validate_source_id(values["id"])
    if not (values.get("name") or "").strip():
        raise WbError("Anzeigename fehlt.", "source_name")
    if values["space"] not in SPACES:
        raise WbError("Wissensraum muss business oder private sein.", "source_space")
    if values["kind"] not in SOURCE_KINDS:
        raise WbError(f"Unbekannter Quellentyp: {values['kind']}", "source_kind")
    if values["confidentiality"] not in CONFIDENTIALITY:
        raise WbError("Unbekannte Vertraulichkeit.", "source_confidentiality")
    locator = str(Path(values["path"]).expanduser()) if values.get("path") else None
    if locator and not Path(locator).is_absolute():
        raise WbError("Quellenpfad muss absolut sein.", "source_path")
    if not locator:
        raise WbError("Im lesenden Pilotkern ist ein lokaler Pfad erforderlich.", "source_path")
    if store.db.execute("SELECT 1 FROM source WHERE id=?", (source_id,)).fetchone():
        raise WbError(f"Quelle {source_id} existiert bereits.", "source_exists")
    now = utc_now()
    origin = {
        "organisation": values.get("organisation") or "",
        "owner": values.get("owner") or "",
        "acquisition": values.get("acquisition") or "lokaler Ordner",
        "usage_rights": values.get("usage") or "",
        "authorization": values.get("authorization") or "",
        "origin_ref": values.get("origin_ref") or "",
    }
    with store.transaction():
        store.db.execute(
            "INSERT INTO source(id,name,kind,space,confidentiality,canonical,origin_json,retention,status,created_at,updated_at) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (source_id, values["name"], values["kind"], values["space"], values["confidentiality"],
             1 if values.get("canonical") else 0, json.dumps(origin, ensure_ascii=False, sort_keys=True),
             values.get("retention") or "keep", "active", now, now),
        )
        store.db.execute(
            "INSERT INTO source_binding(id,source_id,computer_id,binding_key,kind,locator_fingerprint,credential_ref,read,write,derive,state,last_check_at) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            ("bnd-" + uuid.uuid4().hex, source_id, store.computer_id(), "bind-" + source_id,
             "local_path", binding_fingerprint(locator), values.get("credential_ref"),
             1 if values.get("read", True) else 0, 1 if values.get("write") else 0,
             1 if values.get("derive", True) else 0, "unknown", None),
        )
        store.event("source.added", "source", source_id,
                    {"space": values["space"], "kind": values["kind"], "confidentiality": values["confidentiality"],
                     "observed_rights": "unknown"})
    set_binding(config, {
        "source_id": source_id,
        "binding_key": "bind-" + source_id,
        "kind": "local_path",
        "locator": locator,
        "credential_ref": values.get("credential_ref"),
    })
    save_config(config, config_path)
    probe = acl.probe_binding(store, get_source(store, source_id), locator)
    return {"source_id": source_id, "binding_key": "bind-" + source_id, "state": probe["state"],
            "observed_read": probe["observed_read"], "observed_write": probe["observed_write"]}


def get_source(store, source_id: str):
    row = store.db.execute("SELECT * FROM source WHERE id=?", (source_id,)).fetchone()
    if row is None:
        raise WbError(f"Quelle {source_id} nicht gefunden.", "source_missing", 2)
    return row


def list_sources(store, config: dict) -> list[dict]:
    result = []
    for row in store.db.execute("SELECT * FROM source ORDER BY id").fetchall():
        binding = acl.binding_row(store, row["id"])
        configured = binding_for(config, row["id"]) if config else None
        counts = store.db.execute(
            "SELECT (SELECT count(*) FROM item WHERE source_id=? AND removed_at IS NULL) AS items, "
            "(SELECT count(*) FROM version v JOIN item i ON i.id=v.item_id WHERE i.source_id=?) AS versions",
            (row["id"], row["id"]),
        ).fetchone()
        result.append({
            "id": row["id"],
            "name": row["name"],
            "kind": row["kind"],
            "space": row["space"],
            "confidentiality": row["confidentiality"],
            "canonical": bool(row["canonical"]),
            "origin": json.loads(row["origin_json"]),
            "status": row["status"],
            "items": counts["items"],
            "versions": counts["versions"],
            "binding": {
                "configured": bool(configured),
                "read": bool(binding["read"]) if binding else None,
                "write": bool(binding["write"]) if binding else None,
                "derive": bool(binding["derive"]) if binding else None,
                "state": binding["state"] if binding else "unknown",
                "observed_read": bool(binding["observed_read"]) if binding and binding["observed_read"] is not None else None,
                "observed_write": bool(binding["observed_write"]) if binding and binding["observed_write"] is not None else None,
                "access_method": binding["access_method"] if binding else None,
                "access_checked_at": binding["access_checked_at"] if binding else None,
                "last_success_at": binding["last_success_at"] if binding else None,
                "last_error": binding["last_error"] if binding else None,
                "fingerprint": binding["locator_fingerprint"] if binding else None,
            },
        })
    return result


def probe(store, config: dict, source_id: str | None = None) -> dict:
    rows = [get_source(store, source_id)] if source_id else store.db.execute("SELECT * FROM source ORDER BY id").fetchall()
    results = []
    context = store.transaction() if not store.readonly else _null_context()
    with context:
        for row in rows:
            configured = binding_for(config, row["id"])
            result = acl.probe_binding(store, row, configured.get("locator") if configured else None)
            results.append({"source_id": row["id"], **result})
    return {"sources": results}


class _null_context:
    def __enter__(self):
        return None

    def __exit__(self, *args):
        return False
