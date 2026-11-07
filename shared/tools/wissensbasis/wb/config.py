"""Rechnerkonfiguration: Pfade, Bindungen, Computer-ID. Keine Geheimnisse im Store."""
from __future__ import annotations

import json
import os
import uuid
from pathlib import Path

from .util import WbError, atomic_write_text

CONFIG_SCHEMA = "wb/config/v1"


def default_config_path() -> Path:
    override = os.environ.get("WB_CONFIG")
    if override:
        return Path(override).expanduser()
    base = os.environ.get("LOCALAPPDATA") or str(Path.home())
    return Path(base) / "AI-OS" / "Wissensbasis" / "config.json"


def _new_computer_id() -> str:
    return "pc-" + uuid.uuid4().hex


def empty_config() -> dict:
    return {
        "schema": CONFIG_SCHEMA,
        "store_root": None,
        "computer_id": _new_computer_id(),
        "computer_name": os.environ.get("COMPUTERNAME") or os.environ.get("HOSTNAME") or "unbekannt",
        "bindings": [],
        "write_back": False,
        "default_space": None,
    }


def load_config(path: Path | None = None) -> dict:
    target = Path(path) if path else default_config_path()
    if not target.exists():
        return empty_config()
    try:
        value = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise WbError(f"Lokale Konfiguration ist nicht lesbar: {exc}", "config_invalid", 2) from exc
    if not isinstance(value, dict) or value.get("schema") != CONFIG_SCHEMA:
        raise WbError("Lokale Konfiguration hat ein unbekanntes Format.", "config_schema")
    if not value.get("computer_id"):
        value["computer_id"] = _new_computer_id()
    value.setdefault("bindings", [])
    value.setdefault("write_back", False)
    return value


def save_config(config: dict, path: Path | None = None) -> Path:
    target = Path(path) if path else default_config_path()
    atomic_write_text(target, json.dumps(config, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    return target


def binding_for(config: dict, source_id: str) -> dict | None:
    for binding in config.get("bindings", []):
        if str(binding.get("source_id")) == source_id:
            return binding
    return None


def set_binding(config: dict, binding: dict) -> None:
    bindings = [item for item in config.get("bindings", []) if item.get("source_id") != binding["source_id"]]
    bindings.append(binding)
    config["bindings"] = bindings


def resolve_store_root(explicit: str | None, config: dict) -> Path:
    value = explicit or config.get("store_root")
    if not value:
        raise WbError("Kein Store angegeben. --root verwenden oder config.json mit store_root füllen.", "store_missing")
    return Path(value).expanduser()
