"""Kommandozeile des lesenden Pilotkerns. Vertrag: JSON-Huelle `wb/v1`."""
from __future__ import annotations

import argparse
import sys
import traceback
from pathlib import Path

from . import __version__
from . import acl, indexer, ledger, ops, sources
from .config import binding_for, default_config_path, load_config, resolve_store_root
from .importer import import_all, import_source, parse_formats
from .store import init_store, open_store, store_summary
from .util import WbError, emit, envelope, utc_now


def _common() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="JSON-Ausgabe (wb/v1)")
    parser.add_argument("--config", default=argparse.SUPPRESS, help="Pfad zur lokalen Konfiguration")
    parser.add_argument("--root", default=argparse.SUPPRESS, help="Store-Wurzel (ueberschreibt die Konfiguration)")
    return parser


def build_parser() -> argparse.ArgumentParser:
    common = _common()
    parser = argparse.ArgumentParser(
        prog="wb",
        description="AI-OS Wissensbasis — lesender Pilotkern (Import, Herkunft, Originalabruf, Suche, Index, Backup).",
        epilog="Semantische Suche und Wissensverdichtung sind ausdruecklich noch nicht implementiert.",
        parents=[common],
    )
    parser.add_argument("--version", action="version", version=f"wb {__version__}")
    sub = parser.add_subparsers(dest="command", metavar="BEFEHL")

    p = sub.add_parser("init", parents=[common], help="Store anlegen")
    p.set_defaults(handler="init")

    sub.add_parser("status", parents=[common], help="Store-Uebersicht").set_defaults(handler="status")
    sub.add_parser("doctor", parents=[common], help="Store und Konfiguration pruefen").set_defaults(handler="doctor")

    source = sub.add_parser("source", parents=[common], help="Quellenregister")
    source_sub = source.add_subparsers(dest="source_command", required=True)
    add = source_sub.add_parser("add", parents=[common], help="Quelle registrieren")
    add.add_argument("--id", required=True)
    add.add_argument("--name", required=True)
    add.add_argument("--space", required=True, choices=["business", "private"])
    add.add_argument("--kind", default="folder", choices=sorted(sources.SOURCE_KINDS))
    add.add_argument("--path", required=True)
    add.add_argument("--confidentiality", default="internal", choices=sorted(sources.CONFIDENTIALITY))
    add.add_argument("--organisation", default="")
    add.add_argument("--owner", default="")
    add.add_argument("--acquisition", default="")
    add.add_argument("--usage", default="")
    add.add_argument("--authorization", default="")
    add.add_argument("--origin-ref", default="")
    add.add_argument("--canonical", action="store_true")
    add.add_argument("--no-read", action="store_true")
    add.add_argument("--write", action="store_true")
    add.add_argument("--no-derive", action="store_true")
    add.add_argument("--credential-ref", default=None)
    add.add_argument("--retention", default="keep")
    add.set_defaults(handler="source_add")
    source_sub.add_parser("list", parents=[common], help="Quellen anzeigen").set_defaults(handler="source_list")
    probe = source_sub.add_parser("probe", parents=[common], help="Erreichbarkeit und Dateizugriff pruefen")
    probe.add_argument("--source")
    probe.set_defaults(handler="source_probe")

    imp = sub.add_parser("import", parents=[common], help="Quellen lesen und Fassungen erfassen")
    imp.add_argument("--source")
    imp.add_argument("--all", action="store_true")
    imp.add_argument("--dry-run", action="store_true")
    imp.add_argument("--formats", help="Kommaliste, z. B. md,txt,docx; Standard ohne PDF")
    imp.add_argument("--max-bytes", type=int, default=200 * 1024 * 1024)
    imp.add_argument("--no-index", action="store_true")
    imp.set_defaults(handler="import")

    item = sub.add_parser("item", parents=[common], help="Elemente und Fassungen")
    item_sub = item.add_subparsers(dest="item_command", required=True)
    listing = item_sub.add_parser("list", parents=[common], help="Elemente auflisten")
    listing.add_argument("--source")
    listing.add_argument("--limit", type=int, default=100)
    listing.add_argument("--include-removed", action="store_true")
    listing.set_defaults(handler="item_list")
    show = item_sub.add_parser("show", parents=[common], help="Element mit Fassungen und Herkunft")
    show.add_argument("identifier")
    show.set_defaults(handler="item_show")

    original = sub.add_parser("original", parents=[common], help="Original lesend abrufen (Hash-geprueft)")
    original.add_argument("identifier")
    original.add_argument("--out", required=True)
    original.add_argument("--force", action="store_true")
    original.set_defaults(handler="original")

    search = sub.add_parser("search", parents=[common], help="Volltextsuche (lexikalisch, FTS5)")
    search.add_argument("query", nargs="+")
    search.add_argument("--limit", type=int, default=50)
    search.add_argument("--any", action="store_true")
    search.add_argument("--space", choices=["business", "private"])
    search.add_argument("--principal")
    search.set_defaults(handler="search")

    index = sub.add_parser("index", parents=[common], help="Suchindex")
    index_sub = index.add_subparsers(dest="index_command", required=True)
    index_sub.add_parser("rebuild", parents=[common], help="Index neu bauen").set_defaults(handler="index_rebuild")
    index_sub.add_parser("status", parents=[common], help="Indexstatus").set_defaults(handler="index_status")

    note = sub.add_parser("note", parents=[common], help="Store-Notizen (W1)")
    note_sub = note.add_subparsers(dest="note_command", required=True)
    note_add = note_sub.add_parser("add", parents=[common], help="Notiz anlegen")
    note_add.add_argument("--title", required=True)
    note_add.add_argument("--file", required=True)
    note_add.add_argument("--space", required=True, choices=["business", "private", "mixed"])
    note_add.add_argument("--confidentiality", choices=["public", "internal", "confidential", "restricted"])
    note_add.add_argument("--author")
    note_add.set_defaults(handler="note_add")
    note_sub.add_parser("list", parents=[common], help="Notizen auflisten").set_defaults(handler="note_list")
    note_show = note_sub.add_parser("show", parents=[common], help="Notiz mit Fassung und Reviews")
    note_show.add_argument("knowledge_id")
    note_show.add_argument("--principal")
    note_show.set_defaults(handler="note_show")

    knowledge = sub.add_parser("knowledge", parents=[common], help="Abgeleitetes Wissen mit Belegen")
    knowledge_sub = knowledge.add_subparsers(dest="knowledge_command", required=True)
    knowledge_add = knowledge_sub.add_parser("add", parents=[common], help="Belegpflichtiges Wissen anlegen")
    knowledge_add.add_argument("--kind", required=True, choices=["claim", "summary", "decision", "register_entry"])
    knowledge_add.add_argument("--title", required=True)
    knowledge_add.add_argument("--file", required=True)
    knowledge_add.add_argument("--basis", nargs="+", required=True, help="Fassungs-IDs (ver-...)")
    knowledge_add.add_argument("--author")
    knowledge_add.set_defaults(handler="knowledge_add")
    knowledge_show = knowledge_sub.add_parser("show", parents=[common], help="Wissen mit Herkunft und Reviews")
    knowledge_show.add_argument("knowledge_id")
    knowledge_show.add_argument("--principal")
    knowledge_show.set_defaults(handler="knowledge_show")
    knowledge_revise = knowledge_sub.add_parser("revise", parents=[common], help="Neue Fassung eines Wissens anlegen")
    knowledge_revise.add_argument("knowledge_id")
    knowledge_revise.add_argument("--file", required=True)
    knowledge_revise.add_argument("--reason")
    knowledge_revise.add_argument("--base-version")
    knowledge_revise.add_argument("--basis-hash")
    knowledge_revise.add_argument("--basis", nargs="+")
    knowledge_revise.add_argument("--author")
    knowledge_revise.set_defaults(handler="knowledge_revise")
    knowledge_version = knowledge_sub.add_parser("version", parents=[common], help="Einzelne Wissensfassung lesen")
    knowledge_version.add_argument("version_id")
    knowledge_version.add_argument("--principal")
    knowledge_version.set_defaults(handler="knowledge_version")

    evidence = sub.add_parser("evidence", parents=[common], help="Historische Fassung samt Text abrufen")
    evidence.add_argument("version_id")
    evidence.add_argument("--principal")
    evidence.set_defaults(handler="evidence")

    ocr = sub.add_parser("ocr", parents=[common], help="OCR fuer ausstehende PDF-Seiten (eigener Schritt)")
    ocr.add_argument("version_id")
    ocr.add_argument("--no-index", action="store_true")
    ocr.set_defaults(handler="ocr")

    review = sub.add_parser("review", parents=[common], help="Manuelle Bestaetigungen")
    review_sub = review.add_subparsers(dest="review_command", required=True)
    confirm = review_sub.add_parser("confirm", parents=[common], help="Wissensfassung bestaetigen")
    confirm.add_argument("knowledge_version_id")
    confirm.add_argument("--basis-hash")
    confirm.add_argument("--note")
    confirm.add_argument("--reviewer")
    confirm.set_defaults(handler="review_confirm")
    reject = review_sub.add_parser("reject", parents=[common], help="Wissensfassung ablehnen")
    reject.add_argument("knowledge_version_id")
    reject.add_argument("--note")
    reject.add_argument("--reviewer")
    reject.set_defaults(handler="review_reject")
    review_status = review_sub.add_parser("status", parents=[common], help="Bestatigungen anzeigen")
    review_status.add_argument("--knowledge")
    review_status.set_defaults(handler="review_status")

    acl_parser = sub.add_parser("acl", parents=[common], help="Zugriffspruefungen")
    acl_sub = acl_parser.add_subparsers(dest="acl_command", required=True)
    acl_check = acl_sub.add_parser("check", parents=[common], help="Zugriff auf Quelle oder Wissen pruefen")
    acl_check.add_argument("--source")
    acl_check.add_argument("--knowledge")
    acl_check.add_argument("--principal")
    acl_check.set_defaults(handler="acl_check")
    acl_sub.add_parser("recheck", parents=[common], help="Quellenzugriff neu pruefen").set_defaults(handler="acl_recheck")

    verify = sub.add_parser("verify", parents=[common], help="Integritaet pruefen")
    verify.add_argument("--access", action="store_true", help="aktuellen Quellenzugriff mitpruefen")
    verify.set_defaults(handler="verify")

    backup = sub.add_parser("backup", parents=[common], help="Konsistente Sicherung")
    backup.add_argument("--out", required=True)
    backup.set_defaults(handler="backup")

    restore = sub.add_parser("restore", parents=[common], help="Sicherung oder Paket lokal wiederherstellen")
    restore.add_argument("--from", dest="source_dir", required=True)
    restore.add_argument("--readonly", action="store_true")
    restore.add_argument("--no-index", action="store_true")
    restore.set_defaults(handler="restore")

    package = sub.add_parser("package", parents=[common], help="Schreibgeschuetztes Austauschpaket")
    package_sub = package.add_subparsers(dest="package_command", required=True)
    package_create = package_sub.add_parser("create", parents=[common], help="Paket erzeugen")
    package_create.add_argument("--out", required=True)
    package_create.set_defaults(handler="package_create")

    gc = sub.add_parser("gc", parents=[common], help="Temporaeres und verwaiste Blobs bereinigen")
    gc.set_defaults(handler="gc")
    return parser


class Context:
    def __init__(self, args):
        self.args = args
        self.config_path = Path(args.config).expanduser() if getattr(args, "config", None) else default_config_path()
        self.config = load_config(self.config_path)
        self.store = None

    def open(self, writable: bool = False):
        root = resolve_store_root(getattr(self.args, "root", None), self.config)
        self.store = open_store(root, writable=writable)
        return self.store

    def close(self):
        if self.store is not None:
            self.store.close()
            self.store = None


def _handle(ctx: Context, handler: str):
    args = ctx.args
    if handler == "init":
        root = resolve_store_root(getattr(args, "root", None), ctx.config)
        store = init_store(root, ctx.config, ctx.config_path)
        ctx.store = store
        return {"created": True, "summary": store_summary(store)}
    if handler == "restore":
        if not getattr(args, "root", None):
            raise WbError("Fuer restore ist --root (Ziel) erforderlich.", "restore_target")
        result = ops.restore(args.source_dir, args.root, readonly=args.readonly, rebuild=not args.no_index)
        ctx.store = open_store(Path(args.root), writable=False)
        return result
    if handler == "source_add":
        store = ctx.open(writable=True)
        values = {
            "id": args.id, "name": args.name, "space": args.space, "kind": args.kind, "path": args.path,
            "confidentiality": args.confidentiality, "organisation": args.organisation, "owner": args.owner,
            "acquisition": args.acquisition, "usage": args.usage, "authorization": args.authorization,
            "origin_ref": args.origin_ref, "canonical": args.canonical, "read": not args.no_read,
            "write": args.write, "derive": not args.no_derive, "credential_ref": args.credential_ref,
            "retention": args.retention,
        }
        with store.lock():
            return sources.add_source(store, ctx.config, ctx.config_path, values)
    if handler in ("status", "doctor"):
        store = ctx.open()
        if handler == "status":
            return {"summary": store_summary(store), "index": indexer.index_status(store),
                    "actor": store.meta("actor", "owner"),
                    "data_classes": store.manifest.get("data_classes", {}),
                    "configured_bindings": len(ctx.config.get("bindings", [])),
                    "write_back": bool(ctx.config.get("write_back"))}
        return ops.doctor(store)
    if handler == "source_list":
        return sources.list_sources(ctx.open(), ctx.config)
    if handler == "source_probe":
        store = ctx.open()
        if not store.readonly:
            with store.lock():
                return sources.probe(store, ctx.config, args.source)
        return sources.probe(store, ctx.config, args.source)
    if handler == "import":
        store = ctx.open(writable=True)
        formats = parse_formats(args.formats)
        if not args.all and not args.source:
            raise WbError("Entweder --source ID oder --all angeben.", "import_target")
        with store.lock():
            if args.dry_run:
                report = (import_source(store, ctx.config, args.source, formats, args.max_bytes, True)
                          if args.source else import_all(store, ctx.config, formats, args.max_bytes, True))
                return {"report": report, "index": None}
            report = (import_source(store, ctx.config, args.source, formats, args.max_bytes, False)
                      if args.source else import_all(store, ctx.config, formats, args.max_bytes, False))
            index = None if args.no_index else indexer.rebuild(store)
            return {"report": report, "index": index}
    if handler == "item_list":
        return ledger.list_items(ctx.open(), args.source, args.limit, args.include_removed)
    if handler == "item_show":
        return ledger.item_detail(ctx.open(), ctx.config, args.identifier)
    if handler == "original":
        store = ctx.open()
        with store.lock(require_leader=False):
            return ledger.original(store, ctx.config, args.identifier, args.out, args.force)
    if handler == "search":
        return indexer.search(ctx.open(), ctx.config, " ".join(args.query), args.limit, args.any, args.space, args.principal)
    if handler == "index_rebuild":
        store = ctx.open()
        with store.lock(require_leader=False):
            return indexer.rebuild(store)
    if handler == "index_status":
        return indexer.index_status(ctx.open())
    if handler == "note_add":
        store = ctx.open(writable=True)
        with store.lock():
            return ledger.add_note(store, args.title, args.file, args.space, args.confidentiality, args.author)
    if handler == "note_list":
        return ledger.list_notes(ctx.open())
    if handler == "note_show":
        return ledger.note_detail(ctx.open(), args.knowledge_id, ctx.config, args.principal)
    if handler == "knowledge_add":
        store = ctx.open(writable=True)
        with store.lock():
            return ledger.add_claim(store, ctx.config, args.kind, args.title, args.file, args.basis, args.author)
    if handler == "knowledge_show":
        return ledger.note_detail(ctx.open(), args.knowledge_id, ctx.config, args.principal)
    if handler == "knowledge_revise":
        store = ctx.open(writable=True)
        with store.lock():
            return ledger.revise(store, args.knowledge_id, args.file, args.author, args.reason,
                                 args.base_version, args.basis_hash, args.basis, ctx.config)
    if handler == "knowledge_version":
        return ledger.version_detail(ctx.open(), ctx.config, args.version_id, args.principal)
    if handler == "evidence":
        return ledger.evidence(ctx.open(), ctx.config, args.version_id, args.principal)
    if handler == "ocr":
        store = ctx.open(writable=True)
        with store.lock():
            result = ledger.ocr_version(store, ctx.config, args.version_id)
            index = None if args.no_index else indexer.rebuild(store)
            return {"ocr": result, "index": index}
    if handler == "review_confirm":
        store = ctx.open(writable=True)
        with store.lock():
            return ledger.confirm(store, args.knowledge_version_id, args.reviewer, args.note, args.basis_hash)
    if handler == "review_reject":
        store = ctx.open(writable=True)
        with store.lock():
            return ledger.reject(store, args.knowledge_version_id, args.reviewer, args.note)
    if handler == "review_status":
        store = ctx.open()
        sql = ("SELECT r.* FROM review r JOIN knowledge_version kv ON kv.id=r.knowledge_version_id "
               "WHERE (? IS NULL OR kv.knowledge_id=?) ORDER BY r.decided_at")
        rows = store.db.execute(sql, (args.knowledge, args.knowledge)).fetchall()
        return [dict(row) for row in rows]
    if handler == "acl_check":
        store = ctx.open()
        principal = args.principal or store.meta("actor", "owner")
        if args.source:
            source = sources.get_source(store, args.source)
            binding = binding_for(ctx.config, args.source)
            return acl.source_access(store, source, principal, binding.get("locator") if binding else None)
        if args.knowledge:
            row = store.db.execute("SELECT * FROM knowledge WHERE id=?", (args.knowledge,)).fetchone()
            if row is None:
                raise WbError("Wissen nicht gefunden.", "knowledge_missing", 2)
            return acl.knowledge_access(store, row, principal, ctx.config)
        raise WbError("--source oder --knowledge angeben.", "acl_target")
    if handler == "acl_recheck":
        store = ctx.open()
        if not store.readonly:
            with store.lock():
                return acl.recheck(store, ctx.config)
        return acl.recheck(store, ctx.config)
    if handler == "verify":
        store = ctx.open()
        return ops.verify(store, ctx.config, full=True, access=args.access)
    if handler == "backup":
        store = ctx.open()
        with store.lock(require_leader=False):
            return ops.backup(store, args.out)
    if handler == "package_create":
        store = ctx.open()
        with store.lock(require_leader=False):
            return ops.package_create(store, args.out)
    if handler == "gc":
        store = ctx.open()
        with store.lock(require_leader=False):
            return ops.gc(store)
    raise WbError(f"Unbekannter Befehl: {handler}", "internal")


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "command", None):
        parser.print_help()
        return 2
    handler = args.handler
    as_json = bool(getattr(args, "json", False))
    ctx = Context(args)
    store = None
    try:
        data = _handle(ctx, handler)
        store = ctx.store
        meta = {"tool_version": __version__, "schema_version": store.manifest.get("schema_version", 1) if store else 1,
                "generated_at": utc_now()}
        if store is not None:
            meta["store_id"] = store.manifest["store_id"]
            meta["role"] = store.role
        if handler == "verify" and isinstance(data, dict) and not data.get("ok", True):
            emit(envelope(False, data=data, error={"code": "verify_failed",
                                                   "message": "Integritaetspruefung fehlgeschlagen.",
                                                   "recoverable": False}, meta=meta), as_json)
            return 5
        emit(envelope(True, data, meta=meta), as_json)
        return 0
    except WbError as exc:
        emit(envelope(False, error={"code": exc.code, "message": exc.message, "recoverable": exc.recoverable}), as_json)
        return exc.exit_code
    except Exception as exc:  # pragma: no cover - Schutz gegen unerwartete Fehler
        if __import__("os").environ.get("WB_DEBUG"):
            traceback.print_exc()
        emit(envelope(False, error={"code": "internal", "message": f"Unerwarteter Fehler: {exc}", "recoverable": False}), as_json)
        return 1
    finally:
        ctx.close()
