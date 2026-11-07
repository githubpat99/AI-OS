"""Zugriffspruefung: konfigurierte Rechte, tatsaechlicher Dateizugriff und Raumklassifikation.

Grundsatz: `mixed` ist nur eine Klassifikation. Lesen erfordert zusaetzlich
(a) ein konfiguriertes Leserecht und (b) einen tatsaechlich beobachteten
Lesezugriff auf die Quelle. Fuer abgeleitetes Wissen muessen beide
Bedingungen fuer jede Belegfassung gelten; die Schnittmenge allein genuegt nicht.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

from .util import WbError, utc_now

CONFIDENTIALITY_ORDER = {"public": 0, "internal": 1, "confidential": 2, "restricted": 3}
ALL_ACTIONS = ["read", "derive", "derive_cross_space", "write", "review", "export", "admin"]


def max_confidentiality(values: list[str]) -> str:
    return max(values, key=lambda value: CONFIDENTIALITY_ORDER.get(value, 0), default="internal")


def observe_path(path: Path) -> dict:
    """Tatsaechlicher Zugriff des laufenden Prozesses (Windows-ACL-basiert)."""
    result = {"exists": False, "read": False, "write": False, "method": "os_access", "checked_at": utc_now(), "detail": None}
    try:
        result["exists"] = path.exists()
        if not result["exists"]:
            result["detail"] = "Pfad existiert nicht"
            return result
        result["read"] = os.access(path, os.R_OK | os.X_OK)
        result["write"] = os.access(path, os.W_OK)
        if not result["read"]:
            result["detail"] = "Kein Leserecht fuer den laufenden Benutzer"
    except OSError as exc:
        result["detail"] = f"Zugriffspruefung fehlgeschlagen: {exc}"
    return result


def principal_actions(store, principal: str, scope_type: str, scope_id: str) -> set[str]:
    """Owner ist implizit berechtigt; alle anderen nur ueber explizite Grants."""
    owner = store.meta("actor", "owner")
    if principal == owner:
        return set(ALL_ACTIONS)
    actions: set[str] = set()
    rows = store.db.execute(
        "SELECT actions, scope_type, scope_id FROM grant_row WHERE subject_id=? AND (expires_at IS NULL OR expires_at > ?)",
        (principal, utc_now()),
    ).fetchall()
    for row in rows:
        if row["scope_type"] != scope_type or row["scope_id"] != scope_id:
            continue
        try:
            actions.update(json.loads(row["actions"]))
        except ValueError:
            continue
    return actions


def has_action(store, principal: str, action: str, scope_type: str, scope_id: str) -> bool:
    if action in principal_actions(store, principal, scope_type, scope_id):
        return True
    if scope_type != "store":
        return action in principal_actions(store, principal, "store", store.manifest["store_id"])
    return False


def binding_row(store, source_id: str):
    return store.db.execute(
        "SELECT * FROM source_binding WHERE source_id=? AND computer_id=?",
        (source_id, store.computer_id()),
    ).fetchone()


def record_access(store, scope_type: str, scope_id: str, observed: dict) -> None:
    store.db.execute(
        "INSERT INTO access_check(id,scope_type,scope_id,computer_id,observed_read,observed_write,method,checked_at,detail) "
        "VALUES(?,?,?,?,?,?,?,?,?)",
        ("acc-" + os.urandom(8).hex(), scope_type, scope_id, store.computer_id(),
         1 if observed["read"] else 0, 1 if observed["write"] else 0,
         observed["method"], observed["checked_at"], observed["detail"]),
    )


def probe_binding(store, source_row, locator: str | None) -> dict:
    """Aktualisiert den beobachteten Zugriff einer Bindung und liefert den Zustand."""
    binding = binding_row(store, source_row["id"])
    if binding is None:
        return {"state": "unknown", "observed_read": None, "observed_write": None, "detail": "Keine Bindung fuer diesen Rechner"}
    if store.readonly:
        return {
            "state": binding["state"] if binding["state"] != "reachable" else "unknown",
            "observed_read": binding["observed_read"],
            "observed_write": binding["observed_write"],
            "detail": "Spiegelstore: Quellenzugriff nicht verfuegbar",
        }
    if not locator:
        observed = {"exists": False, "read": False, "write": False, "method": "os_access", "checked_at": utc_now(), "detail": "Kein lokaler Pfad konfiguriert"}
    else:
        observed = observe_path(Path(locator))
        if observed["exists"] and Path(locator).is_dir():
            # Ein Verzeichnis gilt als lesbar, wenn es lesbar und durchsuchbar ist.
            observed["read"] = os.access(locator, os.R_OK | os.X_OK)
    if not observed["exists"]:
        state = "unreachable"
    elif not observed["read"]:
        state = "access_denied"
    else:
        state = "reachable"
    store.db.execute(
        "UPDATE source_binding SET state=?, observed_read=?, observed_write=?, access_method=?, access_checked_at=?, last_check_at=?, last_error=? "
        "WHERE source_id=? AND computer_id=?",
        (state, 1 if observed["read"] else 0, 1 if observed["write"] else 0, observed["method"],
         observed["checked_at"], observed["checked_at"], observed["detail"],
         source_row["id"], store.computer_id()),
    )
    record_access(store, "source_binding", str(binding["id"]), observed)
    store.event("source.probed", "source", source_row["id"],
                {"state": state, "observed_read": bool(observed["read"]), "observed_write": bool(observed["write"]), "detail": observed["detail"]})
    return {"state": state, "observed_read": observed["read"], "observed_write": observed["write"], "detail": observed["detail"]}


def source_access(store, source_row, principal: str, locator: str | None) -> dict:
    """Effektiver Lesezugriff auf eine Quelle fuer einen Principal."""
    from .util import binding_fingerprint

    source_id = source_row["id"]
    binding = binding_row(store, source_id)
    reasons: list[str] = []
    if source_row["status"] != "active":
        reasons.append("Quelle ist nicht aktiv")
    if binding is None:
        reasons.append("Keine Bindung fuer diesen Rechner")
    elif not binding["read"]:
        reasons.append("Leserecht in der Bindung nicht erteilt")
    elif locator and binding["locator_fingerprint"] != binding_fingerprint(locator):
        reasons.append("Bindung passt nicht zur lokalen Konfiguration (Pfad-Fingerprint)")
    direct = has_action(store, principal, "read", "source", source_id) or has_action(store, principal, "read", "space", source_row["space"])
    if not direct:
        reasons.append(f"Kein konfiguriertes Leserecht fuer {principal}")
    if reasons:
        return {"allowed": False, "basis": "configured", "reasons": reasons}
    if principal != store.meta("actor", "owner"):
        return {"allowed": False, "basis": "configured",
                "reasons": ["OS-Zugriff fuer diesen Principal nicht verifizierbar; externer Nachweis erforderlich"]}
    if store.readonly:
        return {"allowed": True, "basis": "package", "reasons": ["Spiegelstore: Zugriff ueber Paket-Snapshot"]}
    live = observe_path(Path(locator)) if locator else {"read": False, "exists": False, "detail": "Kein lokaler Pfad"}
    if not live["read"]:
        return {"allowed": False, "basis": "os_access", "reasons": [live.get("detail") or "Kein tatsaechlicher Lesezugriff"]}
    return {"allowed": True, "basis": "os_access", "reasons": ["Konfiguriertes Recht und tatsaechlicher Lesezugriff beobachtet"]}


def knowledge_access(store, knowledge_row, principal: str, config: dict) -> dict:
    """Zugriff auf Wissen: Klassifikation UND Quellzugriff jeder Belegfassung.

    Notizen ohne Beleg brauchen nur die Klassifikationspruefung. Fuer Belege gilt:
    jede Quelle muss konfiguriert lesbar und tatsaechlich zugaenglich sein.
    """
    from .config import binding_for
    reasons: list[str] = []
    owner = store.meta("actor", "owner")
    if knowledge_row["space"] == "mixed":
        if not has_action(store, principal, "derive_cross_space", "space", "mixed"):
            reasons.append("Gemischter Wissensraum erfordert die Aktion derive_cross_space")
        for space in ("business", "private"):
            if not has_action(store, principal, "read", "space", space):
                reasons.append(f"Kein Leserecht im Wissensraum {space}")
    elif knowledge_row["space"] in ("business", "private"):
        if not (has_action(store, principal, "read", "space", knowledge_row["space"])
                or has_action(store, principal, "read", "knowledge", knowledge_row["id"])):
            reasons.append(f"Kein konfiguriertes Leserecht fuer Wissensraum {knowledge_row['space']}")
    version = store.db.execute(
        "SELECT * FROM knowledge_version WHERE id=?", (knowledge_row["current_version_id"],)
    ).fetchone()
    if version is None:
        return {"allowed": False, "basis": "classification", "reasons": reasons + ["Keine aktuelle Fassung"]}
    evidence = store.db.execute(
        "SELECT DISTINCT v.id AS version_id, i.source_id FROM provenance p "
        "JOIN version v ON v.id = p.evidence_version_id JOIN item i ON i.id = v.item_id "
        "WHERE p.knowledge_version_id=? AND p.evidence_version_id IS NOT NULL",
        (version["id"],),
    ).fetchall()
    for row in evidence:
        source_row = store.db.execute("SELECT * FROM source WHERE id=?", (row["source_id"],)).fetchone()
        binding = binding_for(config, row["source_id"])
        access = source_access(store, source_row, principal, binding.get("locator") if binding else None)
        if not access["allowed"]:
            reasons.extend(access["reasons"])
    if principal != owner:
        reasons.append("OS-Zugriff fuer diesen Principal nicht verifizierbar; nur mit externem Nachweis zulaessig")
    return {"allowed": not reasons, "basis": "evidence", "reasons": reasons}


def recheck(store, config: dict) -> dict:
    from .config import binding_for

    results = []
    for source_row in store.db.execute("SELECT * FROM source WHERE status='active' ORDER BY id").fetchall():
        binding = binding_for(config, source_row["id"])
        locator = binding.get("locator") if binding else None
        result = probe_binding(store, source_row, locator)
        configured = bool(binding and binding.get("read", True))
        mismatch = configured and not result["observed_read"]
        results.append({
            "source_id": source_row["id"],
            "configured_read": configured,
            "observed_read": result["observed_read"],
            "state": result["state"],
            "mismatch": bool(mismatch),
            "detail": result["detail"],
        })
    return {"sources": results, "mismatches": sum(1 for item in results if item["mismatch"])}
