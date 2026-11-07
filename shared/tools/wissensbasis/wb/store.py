"""Store-Lebenszyklus: Manifest, Schema, Sperre, Blobs, Ereignisse."""
from __future__ import annotations

import json
import os
import sqlite3
import sys
import tempfile
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from . import __version__
from .util import WbError, atomic_write_bytes, atomic_write_text, dump_json, sha256_bytes, utc_now

STORE_SCHEMA = "wb/store/v1"
SCHEMA_VERSION = 2
ROLES = ("leader", "mirror")

DATA_CLASSES = {
    "irreplaceable_originals": "Quelldateien; liegen ausserhalb des Stores und werden nicht kopiert.",
    "irreplaceable_ledger": "db/knowledge.sqlite3: Herkunft, Fassungen, Notizen, Bestaetigungen, Rechte, Ereignisse.",
    "replaceable_extracts": "blobs/: extrahierter Text; im Prinzip aus Original und Extraktor reproduzierbar, aber aufwendig.",
    "reproducible_index": "index/: FTS5-Suchindex; jederzeit aus Ledger und Text-Blobs neu baubar.",
    "reproducible_exports": "exports/: abgeleitete Exportpakete.",
    "machine_config": "config.json ausserhalb des Stores: Pfade, Bindungen, Credential-Referenzen.",
}


def is_onedrive_path(path: Path) -> bool:
    lowered = str(path).casefold()
    if os.environ.get("OneDrive") and str(path).casefold().startswith(os.environ["OneDrive"].casefold()):
        return True
    return "\\onedrive" in lowered or "/onedrive" in lowered


def find_git_root(path: Path) -> Path | None:
    current = path.resolve()
    for candidate in [current, *current.parents]:
        if (candidate / ".git").exists():
            return candidate
    return None


def assert_safe_store_root(root: Path) -> None:
    root = root.expanduser().resolve()
    if not root.is_absolute():
        raise WbError("Store-Pfad muss absolut sein.", "store_path")
    if str(root).startswith("\\\\"):
        raise WbError("Ein Store auf einer Netzwerkfreigabe ist nicht zulaessig.", "store_network")
    temp = Path(tempfile.gettempdir()).resolve()
    if root == temp or temp in root.parents:
        raise WbError("Ein Store darf nicht im Temp-Verzeichnis liegen.", "store_temp")
    if is_onedrive_path(root):
        raise WbError("Ein Store darf nicht in OneDrive liegen.", "store_onedrive")
    git_root = find_git_root(root)
    if git_root is not None:
        raise WbError(f"Ein Store darf nicht in einem Git-Repository liegen ({git_root}).", "store_repo")
    local = os.environ.get("LOCALAPPDATA")
    if local and str(root).casefold().startswith(str(Path(local).resolve()).casefold()):
        raise WbError("Ein Store darf nicht unter LOCALAPPDATA liegen.", "store_localappdata")


def read_manifest(root: Path) -> dict:
    path = root / "MANIFEST.json"
    if not path.exists():
        raise WbError(f"Kein Wissensbasis-Store unter {root} (MANIFEST.json fehlt).", "store_missing", 2)
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise WbError(f"Store-Manifest ist nicht lesbar: {exc}", "store_manifest") from exc
    if manifest.get("schema") != STORE_SCHEMA:
        raise WbError("Store-Manifest hat ein unbekanntes Format.", "store_manifest")
    if manifest.get("role") not in ROLES:
        raise WbError("Store-Rolle ist ungueltig.", "store_manifest")
    return manifest


class Store:
    def __init__(self, root: Path, db: sqlite3.Connection, manifest: dict):
        self.root = root
        self.db = db
        self.manifest = manifest

    @property
    def role(self) -> str:
        return self.manifest["role"]

    @property
    def readonly(self) -> bool:
        return self.role != "leader"

    def require_writable(self) -> None:
        if self.readonly:
            raise WbError("Dieser Store ist eine schreibgeschuetzte Spiegelung. Aenderungen nur im fuehrenden Store.", "store_readonly", 3)

    def transaction(self):
        return _transaction(self.db)

    def meta(self, key: str, default: str | None = None) -> str | None:
        row = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else default

    def set_meta(self, key: str, value: str) -> None:
        self.db.execute("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))

    def computer_id(self) -> str:
        row = self.db.execute("SELECT id FROM computer ORDER BY first_seen_at LIMIT 1").fetchone()
        if not row:
            raise WbError("Store enthaelt keinen Rechner.", "store_invalid", 5)
        return row[0]

    def computer_name(self) -> str:
        row = self.db.execute("SELECT name FROM computer ORDER BY first_seen_at LIMIT 1").fetchone()
        return row[0] if row else "unbekannt"

    def blob_rel(self, digest: str) -> Path:
        return Path("blobs") / "sha256" / digest[:2] / digest[2:4] / digest

    def blob_path(self, digest: str) -> Path:
        return self.root / self.blob_rel(digest)

    def put_blob(self, data: bytes, media_type: str) -> str:
        digest = sha256_bytes(data)
        rel = self.blob_rel(digest)
        target = self.root / rel
        if not target.exists():
            atomic_write_bytes(target, data)
        if target.stat().st_size != len(data):
            raise WbError("Blob-Groesse stimmt nicht mit dem Inhalt ueberein.", "blob_integrity", 5, False)
        self.db.execute(
            "INSERT INTO blob(hash,rel,size,media_type,created_at) VALUES(?,?,?,?,?) "
            "ON CONFLICT(hash) DO NOTHING",
            (digest, rel.as_posix(), len(data), media_type, utc_now()),
        )
        return digest

    def read_blob(self, digest: str) -> bytes:
        path = self.blob_path(digest)
        if not path.exists():
            raise WbError(f"Text-Blob fehlt: {digest[:12]}…", "blob_missing", 5, False)
        data = path.read_bytes()
        if sha256_bytes(data) != digest:
            raise WbError(f"Text-Blob ist beschaedigt: {digest[:12]}…", "blob_integrity", 5, False)
        return data

    def event(self, event_type: str, entity_type: str, entity_id: str, payload: dict | None = None, actor: str = "cli") -> None:
        event_id = "evt-" + uuid.uuid4().hex
        at = utc_now()
        body = dump_json(payload or {})
        self.db.execute(
            "INSERT INTO event(id,at,type,entity_type,entity_id,actor,computer_id,payload_json) VALUES(?,?,?,?,?,?,?,?)",
            (event_id, at, event_type, entity_type, entity_id, actor, self.computer_id(), body),
        )
        journal = self.root / "journal" / ("events-" + at[:7] + ".jsonl")
        journal.parent.mkdir(parents=True, exist_ok=True)
        with journal.open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(dump_json({"id": event_id, "at": at, "type": event_type, "entity_type": entity_type,
                                    "entity_id": entity_id, "actor": actor, "computer_id": self.computer_id(),
                                    "payload": payload or {}}) + "\n")

    @contextmanager
    def lock(self, require_leader: bool = True, timeout_note: str = ""):
        if require_leader:
            self.require_writable()
        lock_path = self.root / "locks" / "store.lock"
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        payload = dump_json({"pid": os.getpid(), "at": utc_now(), "host": os.environ.get("COMPUTERNAME", "?")})
        for attempt in (0, 1):
            try:
                descriptor = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                    stream.write(payload)
                break
            except FileExistsError:
                try:
                    age = datetime.now(timezone.utc).timestamp() - lock_path.stat().st_mtime
                except OSError:
                    age = 0
                if attempt == 0 and age > 6 * 3600:
                    lock_path.unlink(missing_ok=True)
                    continue
                raise WbError("Store ist durch einen anderen Vorgang gesperrt. " + timeout_note, "store_locked", 6)
        try:
            yield
        finally:
            lock_path.unlink(missing_ok=True)

    def close(self) -> None:
        self.db.close()


@contextmanager
def _transaction(db: sqlite3.Connection):
    db.execute("BEGIN IMMEDIATE")
    try:
        yield
    except Exception:
        db.execute("ROLLBACK")
        raise
    else:
        db.execute("COMMIT")


def _connect(db_path: Path) -> sqlite3.Connection:
    db = sqlite3.connect(str(db_path), timeout=30, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    db.execute("PRAGMA journal_mode = WAL")
    db.execute("PRAGMA synchronous = FULL")
    db.execute("PRAGMA busy_timeout = 30000")
    return db


def _apply_schema(db: sqlite3.Connection) -> None:
    schema_dir = Path(__file__).parent / "schema"
    first = (schema_dir / "001_init.sql").read_text(encoding="utf-8")
    db.executescript(first)
    db.execute("INSERT INTO schema_migrations(version,applied_at,checksum) VALUES(?,?,?)",
               (1, utc_now(), sha256_bytes(first.encode("utf-8"))))
    second = (schema_dir / "002_pdf.sql").read_text(encoding="utf-8")
    db.executescript(second)
    db.execute("INSERT INTO schema_migrations(version,applied_at,checksum) VALUES(?,?,?)",
               (2, utc_now(), sha256_bytes(second.encode("utf-8"))))
    db.execute("INSERT INTO meta(key,value) VALUES(?,?)", ("schema_version", str(SCHEMA_VERSION)))


def _migrate_schema(db: sqlite3.Connection, manifest: dict, root: Path) -> None:
    row = db.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
    current = int(row[0]) if row else 0
    if current > SCHEMA_VERSION:
        raise WbError(f"Store-Schema {current} ist neuer als dieses Werkzeug ({SCHEMA_VERSION}).", "store_schema", 2)
    if current == SCHEMA_VERSION:
        return
    if current < 1:
        raise WbError("Store hat keine Schemaversion.", "store_schema", 5, False)
    second = (Path(__file__).parent / "schema" / "002_pdf.sql").read_text(encoding="utf-8")
    if current < 2:
        columns = {item[1] for item in db.execute("PRAGMA table_info(extraction)").fetchall()}
        if "pages_json" not in columns:
            db.executescript(second)
        db.execute("INSERT OR IGNORE INTO schema_migrations(version,applied_at,checksum) VALUES(?,?,?)",
                   (2, utc_now(), sha256_bytes(second.encode("utf-8"))))
        db.execute("INSERT INTO meta(key,value) VALUES('schema_version',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   (str(SCHEMA_VERSION),))
        manifest["schema_version"] = SCHEMA_VERSION
        atomic_write_text(root / "MANIFEST.json",
                          json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
        db.execute(
            "INSERT INTO event(id,at,type,entity_type,entity_id,actor,computer_id,payload_json) VALUES(?,?,?,?,?,?,?,?)",
            ("evt-" + uuid.uuid4().hex, utc_now(), "store.migrated", "store", manifest["store_id"],
             "cli", "unbekannt", dump_json({"schema_version": SCHEMA_VERSION})),
        )


def init_store(root: Path, config: dict, config_path: Path | None = None) -> Store:
    from .config import save_config

    root = root.expanduser().resolve()
    assert_safe_store_root(root)
    if root.exists() and any(root.iterdir()):
        raise WbError(f"Zielverzeichnis ist nicht leer: {root}", "store_exists")
    for name in ("db", "db/backups", "blobs", "index", "journal", "exports", "tmp", "state", "locks"):
        (root / name).mkdir(parents=True, exist_ok=True)
    store_id = "wb-" + uuid.uuid4().hex[:16]
    manifest = {
        "schema": STORE_SCHEMA,
        "store_id": store_id,
        "role": "leader",
        "created_at": utc_now(),
        "tool_version": __version__,
        "schema_version": SCHEMA_VERSION,
        "data_classes": DATA_CLASSES,
    }
    atomic_write_text(root / "MANIFEST.json", json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    db = _connect(root / "db" / "knowledge.sqlite3")
    try:
        _apply_schema(db)
        db.execute("INSERT INTO meta(key,value) VALUES(?,?)", ("store_id", store_id))
        db.execute("INSERT INTO meta(key,value) VALUES(?,?)", ("created_at", manifest["created_at"]))
        db.execute("INSERT INTO meta(key,value) VALUES(?,?)", ("tool_version", __version__))
        db.execute("INSERT INTO meta(key,value) VALUES(?,?)", ("actor", "owner"))
        db.execute("INSERT INTO computer(id,name,os_user,first_seen_at,last_seen_at) VALUES(?,?,?,?,?)",
                   (config["computer_id"], config.get("computer_name", "unbekannt"), os.environ.get("USERNAME", "unbekannt"), utc_now(), utc_now()))
        store = Store(root, db, manifest)
        store.event("store.created", "store", store_id, {"root": str(root), "role": "leader"})
    except Exception:
        db.close()
        raise
    config["store_root"] = str(root)
    save_config(config, config_path)
    return Store(root, db, manifest)


def open_store(root: Path, writable: bool = False) -> Store:
    root = root.expanduser().resolve()
    manifest = read_manifest(root)
    db = _connect(root / "db" / "knowledge.sqlite3")
    try:
        try:
            _migrate_schema(db, manifest, root)
        except WbError:
            db.close()
            raise
        current = db.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
        if not current or int(current[0]) != SCHEMA_VERSION:
            raise WbError("Store-Schemaversion passt nicht zum Manifest.", "store_schema", 5, False)
        store = Store(root, db, manifest)
        if writable:
            store.require_writable()
        return store
    except Exception:
        db.close()
        raise


def store_summary(store: Store) -> dict:
    def one(sql: str):
        row = store.db.execute(sql).fetchone()
        return row[0] if row else 0

    return {
        "root": str(store.root),
        "store_id": store.manifest["store_id"],
        "role": store.role,
        "computer": {"id": store.computer_id(), "name": store.computer_name()},
        "sources": one("SELECT count(*) FROM source"),
        "items": one("SELECT count(*) FROM item WHERE removed_at IS NULL"),
        "versions": one("SELECT count(*) FROM version"),
        "extractions": one("SELECT count(*) FROM extraction"),
        "text_blobs": one("SELECT count(*) FROM blob"),
        "notes": one("SELECT count(*) FROM knowledge WHERE kind='note' AND archived_at IS NULL"),
        "reviews": one("SELECT count(*) FROM review"),
        "last_event": one("SELECT at FROM event ORDER BY seq DESC LIMIT 1"),
    }


def set_role(store: Store, role: str) -> None:
    if role not in ROLES:
        raise WbError("Unbekannte Store-Rolle.", "store_role")
    store.manifest["role"] = role
    atomic_write_text(store.root / "MANIFEST.json",
                      json.dumps(store.manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    store.event("store.role", "store", store.manifest["store_id"], {"role": role})


def require_writable(store: Store) -> None:
    store.require_writable()


def debug(message: str) -> None:
    if os.environ.get("WB_DEBUG"):
        print(message, file=sys.stderr, flush=True)
