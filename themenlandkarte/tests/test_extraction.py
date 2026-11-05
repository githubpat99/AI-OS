import importlib.util
import tempfile
import unittest
from email.message import EmailMessage
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("document_extraction", Path(__file__).parents[1] / "extract-document.py")
EXTRACTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXTRACTOR)


class ExtractionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_mail_body_without_attachment(self):
        message = EmailMessage()
        message["Subject"] = "MAIL_READER_TEST"
        message["From"] = "fixture@example.invalid"
        message.set_content("Volltext mit Umlaut: Pr\u00fcfung und geheimer Suchbegriff 742.")
        message.add_attachment(b"ATTACHMENT_ONLY_NEVER_INDEX", maintype="application", subtype="octet-stream", filename="attachment.bin")
        path = self.root / "message.eml"
        path.write_bytes(message.as_bytes())
        result = EXTRACTOR.extract_one(path)
        self.assertEqual(result["status"], "partial")
        self.assertIn("Pr\u00fcfung", result["text"])
        self.assertNotIn("ATTACHMENT_ONLY_NEVER_INDEX", result["text"])
        self.assertIn("Anhaenge", result["reason"])

    def test_docx_headings_and_table(self):
        from docx import Document

        document = Document()
        document.add_heading("DOCX_READER_TEST", 1)
        document.add_paragraph("Lesbarer Dokumenttext")
        document.add_table(rows=1, cols=1).cell(0, 0).text = "TABLE_CELL_42"
        path = self.root / "document.docx"
        document.save(path)
        result = EXTRACTOR.extract_one(path)
        self.assertEqual(result["status"], "partial")
        self.assertIn("# DOCX_READER_TEST", result["text"])
        self.assertIn("TABLE_CELL_42", result["text"])

    def test_xlsx_preserves_formula_without_claiming_result(self):
        from openpyxl import Workbook

        document = Workbook()
        document.active["A1"] = "XLSX_READER_TEST"
        document.active["B1"] = "=1+1"
        path = self.root / "sheet.xlsx"
        document.save(path)
        document.close()
        result = EXTRACTOR.extract_one(path)
        self.assertIn("XLSX_READER_TEST", result["text"])
        self.assertIn("=1+1", result["text"])
        self.assertIn("nicht als berechnetes Ergebnis", result["reason"])

    def test_pptx_slide_text(self):
        from pptx import Presentation

        document = Presentation()
        slide = document.slides.add_slide(document.slide_layouts[1])
        slide.shapes.title.text = "PPTX_READER_TEST"
        slide.placeholders[1].text = "Lesbarer Folieninhalt"
        path = self.root / "slides.pptx"
        document.save(path)
        result = EXTRACTOR.extract_one(path)
        self.assertIn("## Folie 1", result["text"])
        self.assertIn("Lesbarer Folieninhalt", result["text"])

    def test_pdf_native_text(self):
        from pypdf import PdfWriter
        from pypdf.generic import DictionaryObject, NameObject, DecodedStreamObject

        writer = PdfWriter()
        page = writer.add_blank_page(width=612, height=792)
        font = DictionaryObject({NameObject("/Type"): NameObject("/Font"), NameObject("/Subtype"): NameObject("/Type1"), NameObject("/BaseFont"): NameObject("/Helvetica")})
        page[NameObject("/Resources")] = DictionaryObject({NameObject("/Font"): DictionaryObject({NameObject("/F1"): writer._add_object(font)})})
        stream = DecodedStreamObject()
        stream.set_data(b"BT /F1 14 Tf 50 700 Td (PDF_NATIVE_TEST with sufficient readable native document text 742) Tj ET")
        page[NameObject("/Contents")] = writer._add_object(stream)
        path = self.root / "native.pdf"
        writer.write(path)
        result = EXTRACTOR.extract_one(path)
        self.assertIn("PDF_NATIVE_TEST", result["text"])
        self.assertEqual(result["metadata"]["ocrPages"], 0)
        self.assertEqual(result["metadata"]["pagesRead"], 1)

    def test_scanned_pdf_uses_local_ocr(self):
        from PIL import Image, ImageDraw, ImageFont

        image = Image.new("RGB", (1800, 600), "white")
        font = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 70)
        ImageDraw.Draw(image).text((90, 150), "LOCAL OCR SAMPLE 2468", fill="black", font=font)
        path = self.root / "scan.pdf"
        image.save(path, "PDF", resolution=144)
        image.close()
        result = EXTRACTOR.extract_one(path)
        self.assertEqual(result["status"], "partial")
        self.assertIn("2468", result["text"])
        self.assertEqual(result["metadata"]["ocrPages"], 1)
        self.assertIn("OCR", result["reason"])

    def test_html_headings_without_active_content(self):
        path = self.root / "page.html"
        path.write_text("<h1>HTML_READER_TEST</h1><p>Lesbarer Inhalt</p><script>NEVER_EXECUTE</script><img src='https://invalid.example/private'>", encoding="utf-8")
        result = EXTRACTOR.extract_one(path)
        self.assertIn("# HTML_READER_TEST", result["text"])
        self.assertNotIn("NEVER_EXECUTE", result["text"])
        self.assertEqual(result["status"], "partial")

    def test_corrupt_pdf_and_msg_are_visible_failures(self):
        for extension in (".pdf", ".msg"):
            path = self.root / ("corrupt" + extension)
            path.write_bytes(b"not a valid document")
            result = EXTRACTOR.extract_one(path)
            self.assertEqual(result["status"], "skipped")
            self.assertEqual(result["text"], "")
            self.assertTrue(result["reason"])

    def test_msg_encoding_fallback_is_visible(self):
        from unittest.mock import MagicMock, patch

        message = MagicMock()
        message.subject = "MSG_READER_TEST"
        message.body = "Text mit Pr\u00fcfung"
        message.sender = "fixture@example.invalid"
        message.to = "fixture@example.invalid"
        message.date = "2026-01-01"
        context = MagicMock()
        context.__enter__.return_value = message
        path = self.root / "message.msg"
        path.write_bytes(b"fixture")
        with patch("extract_msg.Message", side_effect=[UnicodeDecodeError("utf-8", b"\xe4", 0, 1, "invalid"), context]) as factory:
            result = EXTRACTOR.extract_one(path)
            self.assertEqual(factory.call_args.kwargs["overrideEncoding"], "cp1252")
        self.assertIn("Pr\u00fcfung", result["text"])
        self.assertIn("Windows-1252", result["reason"])
        self.assertEqual(result["status"], "partial")


if __name__ == "__main__":
    unittest.main()