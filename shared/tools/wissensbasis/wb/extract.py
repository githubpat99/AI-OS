"""Deterministische Extraktoren ohne Netzwerk und ohne KI.

PDF-Text und OCR laufen optional in einer isolierten Laufzeit
(setup-extractor.ps1); ohne Laufzeit meldet PDF ausdruecklich `unsupported`.
OCR ist ein eigener Schritt und wird nie automatisch beim Import gestartet.
Office-Formate werden ueber den XML-Rueckfall gelesen und als `partial`
gekennzeichnet.
"""
from __future__ import annotations

import email
import email.policy
import json
import os
import re
import subprocess
import zipfile
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path

MAX_CHARS = 1_500_000
PDF_TEXT_MIN_CHARS = 40
PDF_MAX_PAGES = 80
PDF_MAX_OCR_PAGES = 8


def pdf_runtime_python() -> Path | None:
    base = os.environ.get("LOCALAPPDATA")
    if not base:
        return None
    candidate = Path(base) / "AI-OS" / "Wissensbasis" / "runtime" / "Scripts" / "python.exe"
    return candidate if candidate.exists() else None


def _pdf_worker_script() -> Path:
    return Path(__file__).with_name("pdf_worker.py")


def run_pdf_worker(mode: str, path: Path, pages: list[int] | None = None) -> dict:
    python = pdf_runtime_python()
    if python is None:
        raise RuntimeError("PDF-Extraktor-Laufzeit fehlt; setup-extractor.ps1 ausfuehren.")
    command = [str(python), "-I", str(_pdf_worker_script()), "--mode", mode, "--path", str(path),
               "--max-pages", str(PDF_MAX_PAGES), "--max-ocr-pages", str(PDF_MAX_OCR_PAGES)]
    if pages:
        command += ["--pages", ",".join(str(number) for number in pages)]
    completed = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=120)
    if completed.returncode != 0:
        raise RuntimeError((completed.stdout or completed.stderr or "PDF-Extraktor fehlgeschlagen").strip()[:300])
    try:
        result = json.loads(completed.stdout)
    except ValueError as exc:
        raise RuntimeError("PDF-Extraktor lieferte kein gueltiges JSON") from exc
    if not result.get("ok"):
        raise RuntimeError(result.get("error") or "PDF-Extraktor fehlgeschlagen")
    return result


def _pdf_pages(pages: list[dict], truncated: bool = False) -> dict:
    parts: list[str] = []
    metadata: list[dict] = []
    offset = 0
    for entry in pages:
        text = str(entry.get("text", "")).replace("\r\n", "\n").replace("\r", "\n").strip("\n")
        if parts:
            offset += 2
        metadata.append({"page": entry.get("page"), "start": offset, "end": offset + len(text),
                         "chars": len(text), "ocr": bool(entry.get("ocr", False))})
        parts.append(text)
        offset += len(text)
    text = "\n\n".join(parts)
    if len(text) > MAX_CHARS:
        text = text[:MAX_CHARS]
        truncated = True
        kept = []
        for page in metadata:
            if page["start"] >= len(text):
                continue
            page["end"] = min(page["end"], len(text))
            page["chars"] = page["end"] - page["start"]
            kept.append(page)
        metadata = kept
    pending = [page["page"] for page in metadata if page["chars"] < PDF_TEXT_MIN_CHARS and not page["ocr"]]
    return {"text": text, "pages": metadata, "pending_ocr": pending, "truncated": truncated}


def repack_pdf_pages(pages: list[dict]) -> dict:
    """Baut Text und Seitenmetadaten nach einem OCR-Schritt neu auf."""
    return _pdf_pages(pages)


def extract_pdf_with_pages(path: Path) -> dict:
    result = run_pdf_worker("text", path)
    pages = result.get("pages", [])
    if not pages:
        return _result("failed", "pdf-pypdf", reason="PDF enthaelt keine Seiten")
    built = _pdf_pages(pages)
    reason = "PDF-Text; Layout, Tabellen und Bilder nicht ausgewertet"
    if built["pending_ocr"]:
        reason += "; OCR ausstehend fuer Seiten " + ", ".join(str(number) for number in built["pending_ocr"])
    if result.get("total_pages", 0) > result.get("max_pages", PDF_MAX_PAGES):
        reason += f"; nur die ersten {result['max_pages']} Seiten gelesen"
    if built["truncated"]:
        reason += "; Text auf 1.500.000 Zeichen begrenzt"
    return _result("partial", "pdf-pypdf", built["text"], reason, "application/pdf") | {
        "pages": built["pages"], "pending_ocr": built["pending_ocr"]
    }


def extract_pdf_ocr(path: Path, page_numbers: list[int]) -> dict:
    result = run_pdf_worker("ocr", path, page_numbers)
    return {"pages": result.get("pages", []), "skipped_limit": result.get("skipped_limit", [])}

TEXT_FORMATS = {".md", ".markdown", ".txt", ".log", ".csv", ".tsv", ".json", ".yaml", ".yml", ".xml"}
HTML_FORMATS = {".html", ".htm"}
OFFICE_FORMATS = {".docx", ".xlsx", ".pptx"}
MAIL_FORMATS = {".eml"}
PDF_FORMATS = {".pdf"}

SUPPORTED_FORMATS = TEXT_FORMATS | HTML_FORMATS | OFFICE_FORMATS | MAIL_FORMATS


class _HtmlText(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.hidden = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style", "noscript"):
            self.hidden += 1
        if re.fullmatch(r"h[1-6]", tag):
            self.parts.append("\n" + "#" * int(tag[1]) + " ")
        elif tag in ("br", "p", "div", "li", "tr", "td", "section"):
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style", "noscript") and self.hidden:
            self.hidden -= 1

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


def _result(status: str, extractor: str, text: str = "", reason: str | None = None, media_type: str = "text/plain") -> dict:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if len(text) > MAX_CHARS:
        text = text[:MAX_CHARS]
        status = "partial" if status == "full" else status
        reason = (reason + "; " if reason else "") + "Text auf 1.500.000 Zeichen begrenzt"
    return {
        "status": status,
        "extractor": extractor,
        "extractor_version": "1",
        "reason": reason,
        "text": text,
        "media_type": media_type,
        "pages": [],
    }


def _read_text(path: Path) -> str:
    data = path.read_bytes()
    if b"\x00" in data:
        raise ValueError("Binaerinhalt trotz Textendung")
    return data.decode("utf-8-sig", "strict")


def _office_text(path: Path, extension: str) -> tuple[str, str]:
    patterns = {
        ".docx": r"^word/(document|header\d+|footer\d+|footnotes|endnotes)\.xml$",
        ".pptx": r"^ppt/(slides/slide\d+|notesSlides/notesSlide\d+)\.xml$",
        ".xlsx": r"^xl/(sharedStrings|worksheets/sheet\d+)\.xml$",
    }
    pattern = patterns[extension]
    parts: list[str] = []
    with zipfile.ZipFile(path) as archive:
        names = [name for name in archive.namelist() if re.match(pattern, name)]
        for name in names:
            try:
                root = ET.fromstring(archive.read(name))
            except ET.ParseError:
                continue
            for element in root.iter():
                tag = element.tag.rsplit("}", 1)[-1]
                if tag in ("t", "v") and element.text:
                    parts.append(element.text)
    return "\n".join(parts), "Office-XML-Text ohne Layout, Bilder und Formeln"


def _mail_text(path: Path) -> tuple[str, str]:
    raw = path.read_bytes()
    message = email.message_from_bytes(raw, policy=email.policy.default)
    header = "\n".join(
        f"{name}: {message.get(name, '')}" for name in ("From", "To", "Cc", "Subject", "Date") if message.get(name)
    )
    plain: list[str] = []
    formatted: list[str] = []
    for part in message.walk():
        if part.is_multipart():
            continue
        content_type = part.get_content_type()
        if content_type == "text/plain":
            try:
                plain.append(part.get_content())
            except (LookupError, UnicodeError):
                payload = part.get_payload(decode=True) or b""
                plain.append(payload.decode("utf-8", "replace"))
        elif content_type == "text/html":
            try:
                parser = _HtmlText()
                parser.feed(part.get_content())
                formatted.append("".join(parser.parts))
            except (LookupError, UnicodeError):
                pass
    body = "\n\n".join(plain) if plain else "\n\n".join(formatted)
    chunks = [chunk for chunk in (header, body) if chunk.strip()]
    return "\n\n".join(chunks), "Mailtext; Anhaenge und eingebettete Bilder nicht ausgewertet"


def extract_file(path: Path) -> dict:
    extension = path.suffix.casefold()
    media_type = "text/plain"
    try:
        if path.stat().st_size == 0:
            return _result("failed", "empty-v1", reason="Datei ist leer")
        if extension in TEXT_FORMATS:
            text = _read_text(path)
            if extension in (".json",):
                try:
                    json.loads(text)
                except ValueError:
                    return _result("partial", "json-v1", text, "JSON ist nicht gueltig; Rohtext wird durchsucht", "application/json")
            if extension in (".yaml", ".yml", ".xml"):
                media_type = "application/xml"
            return _result("full", extension.lstrip(".") + "-v1", text, None, media_type)
        if extension in HTML_FORMATS:
            parser = _HtmlText()
            parser.feed(_read_text(path))
            return _result("full", "html-v1", "".join(parser.parts), "HTML-Text ohne Script/Style; keine Layout-/Bildauswertung", "text/html")
        if extension in OFFICE_FORMATS:
            text, note = _office_text(path, extension)
            return _result("partial", extension.lstrip(".") + "-xml-v1", text, note,
                           "application/vnd.openxmlformats-officedocument")
        if extension in MAIL_FORMATS:
            text, note = _mail_text(path)
            return _result("partial", "eml-v1", text, note, "message/rfc822")
        if extension in PDF_FORMATS:
            if pdf_runtime_python() is None:
                return _result("unsupported", "pdf-runtime",
                               reason="PDF-Extraktor-Laufzeit fehlt; setup-extractor.ps1 ausfuehren")
            try:
                return extract_pdf_with_pages(path)
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
                return _result("failed", "pdf-pypdf", reason=f"PDF-Auslesefehler: {exc}")
        return _result("unsupported", "none", reason=f"Dateiformat {extension or '(ohne)'} wird nicht ausgelesen")
    except UnicodeDecodeError:
        return _result("failed", "text-v1", reason="Inhalt ist kein gueltiges UTF-8")
    except (OSError, zipfile.BadZipFile, ValueError) as exc:
        return _result("failed", "reader-v1", reason=f"Auslesefehler: {exc}")


def format_supported(extension: str) -> bool:
    return extension.casefold() in SUPPORTED_FORMATS
