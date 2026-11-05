import argparse
import base64
import contextlib
import email.policy
import json
import os
import re
import sys
from email.parser import BytesParser
from pathlib import Path

MAX_CHARACTERS = 1_500_000
MAX_PAGES = 80
MAX_OCR_PAGES = 8
OCR_ENGINE = None


def html_text(value):
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(value, "html.parser")
    for node in soup(["script", "style", "noscript"]):
        node.decompose()
    for heading in soup.find_all(re.compile(r"^h[1-6]$")):
        heading.replace_with("\n" + "#" * int(heading.name[1]) + " " + heading.get_text(" ", strip=True) + "\n")
    return soup.get_text("\n", strip=True)


def extract_pdf(path, warnings):
    from pypdf import PdfReader

    reader = PdfReader(str(path), strict=False)
    if reader.is_encrypted and not reader.decrypt(""):
        raise ValueError("PDF ist verschluesselt")
    warnings.append("PDF-Text und gegebenenfalls OCR; Layout, Tabellen und Bilder nicht vollstaendig ausgewertet")
    pages = []
    ocr_pages = 0
    successful_pages = 0
    total = len(reader.pages)
    for number, page in enumerate(reader.pages[:MAX_PAGES], 1):
        try:
            text = page.extract_text() or ""
            if len(text.strip()) < 40:
                if ocr_pages >= MAX_OCR_PAGES:
                    warnings.append(f"Seite {number}: OCR-Seitenlimit erreicht; Inhalt nicht ausgelesen")
                else:
                    ocr_pages += 1
                    try:
                        import pypdfium2 as pdfium
                        from rapidocr_onnxruntime import RapidOCR

                        global OCR_ENGINE
                        if OCR_ENGINE is None:
                            OCR_ENGINE = RapidOCR()
                        with pdfium.PdfDocument(str(path)) as rendered:
                            rendered_page = rendered[number - 1]
                            bitmap = rendered_page.render(scale=1.8)
                            try:
                                image = bitmap.to_pil().copy()
                                result, _ = OCR_ENGINE(image)
                                recognized = "\n".join(item[1] for item in (result or []))
                                image.close()
                                if recognized.strip():
                                    text = recognized
                                    warnings.append(f"Seite {number}: OCR-Text, Erkennungsfehler moeglich")
                            finally:
                                bitmap.close()
                                rendered_page.close()
                    except Exception as error:
                        warnings.append(f"Seite {number}: OCR fehlgeschlagen ({type(error).__name__})")
            if text.strip():
                successful_pages += 1
                pages.append(f"## Seite {number}\n\n{text.strip()}")
            else:
                warnings.append(f"Seite {number}: kein lesbarer Text; OCR erforderlich oder erfolglos")
        except Exception as error:
            warnings.append(f"Seite {number}: Auslesefehler ({type(error).__name__})")
    if total > MAX_PAGES:
        warnings.append(f"Nur die ersten {MAX_PAGES} von {total} Seiten verarbeitet")
    title = str(reader.metadata.title).strip() if reader.metadata and reader.metadata.title else path.stem
    warnings.append(f"{successful_pages} von {total} PDF-Seiten mit lesbarem Text")
    return "\n\n".join(pages), {"title": title, "pages": total, "pagesRead": successful_pages, "ocrPages": ocr_pages}


def extract_mail(path, warnings):
    warnings.append("Nachrichtenkopf und Nachrichtentext; Anhaenge und eingebettete Bilder nicht ausgelesen")
    if path.suffix.lower() == ".msg":
        import extract_msg

        def read_message(encoding=None):
            options = {"overrideEncoding": encoding} if encoding else {}
            with extract_msg.Message(str(path), **options) as message:
                subject = str(message.subject or path.stem)
                body = message.body or html_text(message.htmlBody or "")
                headers = f"# {subject}\n\nVon: {message.sender or ''}\nAn: {message.to or ''}\nDatum: {message.date or ''}"
                return headers + "\n\n## Nachricht\n\n" + body, {"title": subject}

        try:
            return read_message()
        except UnicodeDecodeError:
            warnings.append("MSG-Zeichenkodierung als Windows-1252 gelesen; Sonderzeichen manuell pruefen")
            return read_message("cp1252")
    with path.open("rb") as source:
        message = BytesParser(policy=email.policy.default).parse(source)
    subject = str(message.get("Subject", path.stem))
    headers = "\n".join(f"{label}: {message.get(key, '')}" for key, label in [("From", "Von"), ("To", "An"), ("Date", "Datum")])
    part = message.get_body(preferencelist=("plain", "html"))
    if part is None:
        warnings.append("Kein lesbarer Nachrichtentext gefunden")
        body = ""
    else:
        try:
            body = part.get_content()
        except (UnicodeError, LookupError):
            body = (part.get_payload(decode=True) or b"").decode("utf-8", errors="replace")
            warnings.append("Zeichenkodierung unvollstaendig erkannt")
        if part.get_content_type() == "text/html":
            body = html_text(body)
    return f"# {subject}\n\n{headers}\n\n## Nachricht\n\n{body}", {"title": subject}


def extract_office(path, warnings):
    extension = path.suffix.lower()
    warnings.append("Office-Text; Bilder, Makros, Kommentare, Layout und eingebettete Objekte nicht vollstaendig ausgewertet")
    sections = []
    if extension == ".docx":
        from docx import Document
        from docx.table import Table
        from docx.text.paragraph import Paragraph

        document = Document(str(path))
        for block in document.iter_inner_content():
            if isinstance(block, Paragraph):
                style = block.style.name if block.style else ""
                level = re.search(r"(?:Heading|Ueberschrift|Title)\s*(\d)?", style, re.I)
                prefix = "#" * int(level.group(1) or 1) + " " if level else ""
                sections.append(prefix + block.text)
            elif isinstance(block, Table):
                sections.extend(" | ".join(cell.text for cell in row.cells) for row in block.rows)
    elif extension == ".xlsx":
        from openpyxl import load_workbook

        document = load_workbook(str(path), read_only=True, data_only=False, keep_links=False)
        warnings.append("Formeln als Ausdruck, nicht als berechnetes Ergebnis gelesen")
        try:
            for sheet in document:
                sections.append("## Tabellenblatt " + sheet.title)
                for number, row in enumerate(sheet.iter_rows(values_only=True), 1):
                    if number > 10000:
                        warnings.append(f"Tabellenblatt {sheet.title}: Zeilenlimit 10000 erreicht")
                        break
                    values = list(row[:200])
                    if len(row) > 200:
                        warnings.append(f"Tabellenblatt {sheet.title}: nur die ersten 200 Spalten gelesen")
                    if any(value is not None for value in values):
                        sections.append(f"Zeile {number}: " + " | ".join("" if value is None else str(value) for value in values))
        finally:
            document.close()
    elif extension == ".pptx":
        from pptx import Presentation

        document = Presentation(str(path))
        for number, slide in enumerate(document.slides, 1):
            sections.append(f"## Folie {number}")
            for shape in slide.shapes:
                if shape.has_text_frame:
                    sections.append(shape.text)
                if shape.has_table:
                    sections.extend(" | ".join(cell.text for cell in row.cells) for row in shape.table.rows)
            if slide.has_notes_slide:
                sections.append("### Notizen\n" + slide.notes_slide.notes_text_frame.text)
    return "\n\n".join(sections), {}


def extract_one(path):
    path = Path(path)
    warnings = []
    result = {"status": "skipped", "text": "", "reason": "", "extraction": "Lokale Parserextraktion", "metadata": {}}
    try:
        if path.stat().st_size > 8 * 1024 * 1024:
            raise ValueError("Datei groesser als 8 MiB; Inhalt nicht gelesen")
        extension = path.suffix.lower()
        if extension == ".pdf":
            text, metadata = extract_pdf(path, warnings)
        elif extension in {".eml", ".msg"}:
            text, metadata = extract_mail(path, warnings)
        elif extension in {".docx", ".xlsx", ".pptx"}:
            text, metadata = extract_office(path, warnings)
        elif extension == ".rtf":
            from striprtf.striprtf import rtf_to_text

            text = rtf_to_text(path.read_text(encoding="cp1252", errors="replace"))
            metadata = {}
            warnings.append("RTF-Text ohne Bilder und eingebettete Objekte")
        elif extension in {".html", ".htm"}:
            text = html_text(path.read_bytes())
            metadata = {}
            warnings.append("HTML-Text und Ueberschriften; Skripte, Styles und Bilder nicht als Inhalt ausgewertet")
        else:
            raise ValueError("Format nicht unterstuetzt")
        if len(text) > MAX_CHARACTERS:
            text = text[:MAX_CHARACTERS]
            warnings.append("Leselimit von 1500000 Zeichen erreicht; Inhalt abgeschnitten")
        if not text.strip():
            raise ValueError("Kein lesbarer Inhalt extrahiert")
        result.update(status="partial", text=text, metadata=metadata)
    except Exception as error:
        warnings.append(str(error) if isinstance(error, ValueError) else "Extraktion fehlgeschlagen: " + type(error).__name__)
    result["reason"] = "; ".join(dict.fromkeys(warnings))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", action="store_true")
    arguments = parser.parse_args()
    if not arguments.server:
        parser.error("--server erforderlich")
    for line in sys.stdin:
        try:
            request = json.loads(line)
            path = base64.b64decode(request["pathBase64"]).decode("utf-8") if "pathBase64" in request else request["path"]
            with contextlib.redirect_stdout(sys.stderr):
                result = extract_one(path)
        except Exception as error:
            result = {"status": "skipped", "text": "", "reason": "Parserfehler: " + type(error).__name__, "extraction": "Lokale Parserextraktion"}
        sys.stdout.write(json.dumps(result, ensure_ascii=True) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    os.environ.setdefault("OMP_NUM_THREADS", "2")
    main()