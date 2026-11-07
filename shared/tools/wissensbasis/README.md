# wb — lesender Wissensbasis-Pilotkern

Lokales Werkzeug (Python 3.10+, nur Standardbibliothek) für Import, Herkunft, Originalabruf, lexikalische Volltextsuche, Index-Rebuild, konsistentes Backup/Restore, schreibgeschützte Austauschpakete sowie optional PDF-Text und OCR in einer isolierten Laufzeit.

**Ausdrücklich nicht enthalten:** semantische Suche, Embeddings, automatische Zusammenfassungen, Wissensverdichtung zu Claims/Entscheidungen, PST/MSG, Schreibzugriff auf Quellen, Oberflächen. OCR ist ein eigener Schritt und läuft nie automatisch beim Import. Profil B mit allen 50 PDFs ist nicht durchgeführt.

Architektur und Grenzen: [`../../wissensbasis/02_ARCHITEKTUR.md`](../../wissensbasis/02_ARCHITEKTUR.md), Datenmodell: [`03_DATENMODELL.md`](../../wissensbasis/03_DATENMODELL.md), Umsetzungsstand: [`07_PILOTKERN.md`](../../wissensbasis/07_PILOTKERN.md), Nachweise PDF/OCR und Belegüberholung: [`09_BELEGUEBERHOLUNG.md`](../../wissensbasis/09_BELEGUEBERHOLUNG.md).

## Voraussetzungen

- Python 3.10+ (lokal geprüft mit 3.14; SQLite mit FTS5/JSON1)
- Store außerhalb von Git-Repositories, `%TEMP%`, OneDrive und `LOCALAPPDATA`
- Lokale Konfiguration unter `%LOCALAPPDATA%\AI-OS\Wissensbasis\config.json` (oder `WB_CONFIG`)
- Für PDF/OCR optional: `.\setup-extractor.ps1` installiert eine isolierte Laufzeit unter `%LOCALAPPDATA%\AI-OS\Wissensbasis\runtime` (uv, Python 3.12, `pypdf`, `pypdfium2`, `rapidocr-onnxruntime`, `Pillow`). Ohne Laufzeit meldet PDF `unsupported` mit Grund.

## Schnellstart

```powershell
cd C:\Users\patri\AI-OS\shared\tools\wissensbasis

# Store anlegen (Pfad prüfen lassen)
python -m wb init --root C:\AI-OS-Wissensbasis

# Quelle registrieren; der absolute Pfad landet nur in der lokalen Konfiguration
python -m wb source add --id src-beispiel --name "Beispiel" --space business `
  --kind folder --path C:\Pfad\zur\Quelle --confidentiality confidential `
  --organisation "AI-Consulting-OS" --authorization "nur lesend"

# Lesen, prüfen, suchen
python -m wb import --source src-beispiel --formats md,txt,html,docx,eml
python -m wb item list
python -m wb search "Zielarchitektur Transformation"
python -m wb verify --access

# Wissen, neue Fassung und Bestätigung
python -m wb knowledge add --kind claim --title "Befund" --file .\befund.md --basis <ver-id>
python -m wb knowledge show <knw-id>
python -m wb knowledge revise <knw-id> --file .\befund-neu.md --base-version <knv-id> --reason "Präzisiert"
python -m wb knowledge version <knv-id>
python -m wb review confirm <knv-id> --basis-hash <hash> --note "Geprüft"
python -m wb review reject <knv-id> --note "Begründung"

# Original lesend und hashgeprüft abrufen
python -m wb original <item-id> --out C:\Abruf

# Sicherung und Read-only-Austausch
python -m wb backup --out G:\AI-OS-Backups\wissensbasis
python -m wb package create --out G:\Austausch\wissensbasis-paket
python -m wb restore --from G:\Austausch\wissensbasis-paket --root C:\AI-OS-Wissensbasis-ReadOnly --readonly

# PDF-Text und OCR (Extraktor-Laufzeit erforderlich)
.\setup-extractor.ps1
python -m wb import --source src-beispiel --formats pdf
python -m wb ocr <version-id>
python -m wb search "Begriff aus dem Scan"
```

Alle Befehle liefern mit `--json` die stabile Hülle `wb/v1`. `--json` ist ASCII-sicher und für Skripte zu bevorzugen; die menschliche Ausgabe enthält Umlaute.

## Rollen

- `leader`: einziger beschreibbarer Store. Import, Quellen, Notizen, Reviews, Originalabruf.
- `mirror`: aus einem Paket wiederhergestellt. Nur Lesen/Suchen/Anzeigen; alle Schreibbefehle enden mit Exit 3. Originalabruf endet mit Exit 4 (kein Quellenzugriff).

## Exit-Codes

| Code | Bedeutung |
| --- | --- |
| 0 | Erfolg |
| 2 | Eingabefehler, fehlender Store/Index, ungültige Quelle |
| 3 | Rechtefehler (auch Spiegelstore, verweigerter Zugriff) |
| 4 | Quellenfehler (nicht erreichbar, Original verändert) |
| 5 | Integritätsfehler (Verify, Blob, Restore) |
| 6 | Konflikt (Lock, Bestätigungsbasis) |

## Datenhaltung

- Kanonisch: `db/knowledge.sqlite3` (Herkunft, Fassungen, Notizen, Bestätigungen, Rechte, Ereignisse).
- Text: `blobs/` (nur extrahierter Text, keine Originalbytes); PDF-Seitenmetadaten stehen in `extraction.pages_json`.
- Wegwerfbar: `index/` (FTS5, `python -m wb index rebuild`); Suchtreffer aus PDFs enthalten die Seite der belegten Zeichenstelle.
- Audit: `journal/*.jsonl`; Sicherungen über `wb backup --out`.
- Originale bleiben unverändert in ihren Quellen.

## Tests

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
```

Sechzehn Tests: Init-Schutz, Import/Idempotenz/Quellenunverändertheit, Herkunft, Originalabruf, Suche/Index-Rebuild, Backup/Restore, Read-only-Paket, Korruptionserkennung, Zugriffsprüfung, `mixed`-Prüfung, Belegstellen-Offsets, Belegüberholung, JSON-Vertrag, PDF-Seitenzuordnung, OCR als eigener Schritt, PDF-Seitenbegrenzung.

## Grenzen

- Nur der lokale Benutzer ist OS-verifiziert; weitere Principals werden ohne externen Nachweis abgelehnt.
- PDF-Text bis 80 Seiten; OCR standardmäßig 8 Seiten pro Lauf; Text bis 1 500 000 Zeichen. Layout, Tabellen und Bilder werden nicht ausgewertet; OCR bleibt `partial` und kann ausstehende Seiten melden.
- PST/MSG, Anhänge und Cloud-/Webquellen sind nicht implementiert.
- Office wird über XML gelesen (`partial`).
- Keine Hintergrundüberwachung; Aktualisierung nur durch `import`.
- Keine Lösch-/Archivierungs-CLI, kein Mehrbenutzerbetrieb, keine Verschlüsselung ruhender Daten.
