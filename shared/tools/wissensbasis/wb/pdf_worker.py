"""PDF-Extraktor, der ausschliesslich in der isolierten Laufzeit laeuft.

Aufruf:
  runtime-python -I pdf_worker.py --mode text --path datei.pdf
  runtime-python -I pdf_worker.py --mode ocr --path datei.pdf --pages 1,3

Ausgabe: genau ein JSON-Objekt auf stdout. Diagnosen auf stderr.
Keine Netzwerkzugriffe, keine Modelle ausser dem lokalen OCR-Modell.
"""
from __future__ import annotations

import argparse
import json
import sys
import traceback


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=True))
    sys.stdout.flush()


def text_mode(path: str, max_pages: int) -> dict:
    from pypdf import PdfReader

    reader = PdfReader(path, strict=False)
    if reader.is_encrypted:
        try:
            if not reader.decrypt(""):
                raise ValueError("PDF ist verschluesselt")
        except Exception as exc:
            raise ValueError(f"PDF ist verschluesselt: {exc}") from exc
    pages = []
    for index, page in enumerate(reader.pages[:max_pages], 1):
        try:
            text = page.extract_text() or ""
        except Exception as exc:
            pages.append({"page": index, "text": "", "error": str(exc)})
            continue
        pages.append({"page": index, "text": text})
    return {"pages": pages, "total_pages": len(reader.pages), "max_pages": max_pages}


def ocr_mode(path: str, page_numbers: list[int], max_pages: int) -> dict:
    import pypdfium2 as pdfium
    from rapidocr_onnxruntime import RapidOCR

    engine = RapidOCR()
    document = pdfium.PdfDocument(path)
    pages = []
    skipped_limit = []
    attempted = 0
    for number in page_numbers:
        if number < 1 or number > len(document):
            pages.append({"page": number, "text": "", "error": "Seite ausserhalb des Dokuments"})
            continue
        if attempted >= max_pages:
            skipped_limit.append(number)
            continue
        attempted += 1
        try:
            bitmap = document[number - 1].render(scale=1.8)
            image = bitmap.to_pil().copy()
            result, _elapsed = engine(image)
            text = "\n".join(str(item[1]) for item in (result or []))
        except Exception as exc:
            pages.append({"page": number, "text": "", "error": str(exc)})
            continue
        pages.append({"page": number, "text": text})
    return {"pages": pages, "skipped_limit": skipped_limit, "total_pages": len(document), "max_pages": max_pages}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["text", "ocr"], required=True)
    parser.add_argument("--path", required=True)
    parser.add_argument("--pages", default="")
    parser.add_argument("--max-pages", type=int, default=80)
    parser.add_argument("--max-ocr-pages", type=int, default=8)
    args = parser.parse_args()
    try:
        if args.mode == "text":
            result = text_mode(args.path, args.max_pages)
        else:
            numbers = [int(value) for value in args.pages.split(",") if value.strip()]
            result = ocr_mode(args.path, numbers, args.max_ocr_pages)
        emit({"ok": True, "mode": args.mode, **result})
        return 0
    except Exception as exc:
        emit({"ok": False, "mode": args.mode, "error": str(exc)})
        print(traceback.format_exc(), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
