# 07 — Lesender Pilotkern: Umsetzungsstand

Stand: 2026-11-05 · Implementiert und getestet · Keine Originale verändert · Keine Visualisierung.

## 1. Was umgesetzt ist

| Funktion | Status | Befehle |
| --- | --- | --- |
| Store anlegen und prüfen | umgesetzt | `wb init`, `wb status`, `wb doctor` |
| Quellenregister mit Herkunft, Bindung, Rechten | umgesetzt | `wb source add`, `source list`, `source probe` |
| Lesender Import mit Fassungen und Extraktion | umgesetzt | `wb import` |
| Herkunft pro Element und Fassung | umgesetzt | `wb item list`, `wb item show` |
| Originalabruf (Hash-geprüft, nur lesend) | umgesetzt | `wb original` |
| Volltextsuche (FTS5, lexikalisch) | umgesetzt | `wb search` |
| Index jederzeit neu bauen | umgesetzt | `wb index rebuild`, `index status` |
| Konsistentes Backup/Restore | umgesetzt | `wb backup`, `wb restore`, `wb verify` |
| Schreibgeschützter Rechner-Austausch | umgesetzt | `wb package create`, `wb restore --readonly` |
| Notizen und manuelle Bestätigungen (W1) | umgesetzt, minimal | `wb note add/list/show`, `wb review confirm/reject/status` |
| Rechteprüfung auf Basis tatsächlichen Dateizugriffs | umgesetzt | `wb acl check`, `wb acl recheck` |
| PDF-Text in isolierter Laufzeit | umgesetzt, an zwei PDFs geprüft | `wb import --formats pdf` |
| OCR als eigener Schritt (Seitenbezug, Limit) | umgesetzt, an einem Scan geprüft | `wb ocr <version-id>` |
| Bereinigung | umgesetzt | `wb gc` |

**Nicht umgesetzt und ausdrücklich später offen:** semantische Suche/Embeddings, automatische Zusammenfassungen, Claims/Entscheidungsverdichtung, PST/MSG, Cloud-/Webquellen, Schreibkanal W2, Hintergrunddienst/Watcher, jede Oberfläche. **Profil B mit allen 50 PDFs** ist nicht durchgeführt.

## 2. Technische Form

- Python 3.10+, ausschließlich Standardbibliothek; SQLite mit FTS5 (lokal geprüft: Python 3.14, SQLite 3.50.4).
- Code: `shared/tools/wissensbasis/wb/` (14 Module; Schema `001_init.sql` und `002_pdf.sql`, Store-Schema **2**).
- PDF/OCR: optionale isolierte Laufzeit unter `%LOCALAPPDATA%\AI-OS\Wissensbasis\runtime`; Einrichtung mit `setup-extractor.ps1`, Pakete in `requirements-extract.txt` (`pypdf`, `pypdfium2`, `rapidocr-onnxruntime`, `Pillow`). Der Kern bleibt ohne diese Laufzeit installierbar.
- Tests: `shared/tools/wissensbasis/tests/test_core.py`, **16 Tests**, Laufzeit ca. 9,0 s, alle bestanden.
- Suchindex: FTS5-Schema **2** mit Seitenzuordnung; ein Index älteren Schemas wird mit `index_stale` abgelehnt und muss mit `wb index rebuild` neu gebaut werden.
- Der Profil-A-Lauf mit echten Quellen ist in [08_PILOTABNAHME.md](08_PILOTABNAHME.md) dokumentiert; Belegüberholung und PDF/OCR in [09_BELEGUEBERHOLUNG.md](09_BELEGUEBERHOLUNG.md).
- Daten: Store außerhalb aller Repositories; **keine Originalbytes im Store**. Gespeichert werden Metadaten, Fassungshashes, extrahierter Text und PDF-Seitenoffsets. `version.original_stored` ist im Pilot immer `0`.
- Konfiguration: `%LOCALAPPDATA%\AI-OS\Wissensbasis\config.json` (bzw. `WB_CONFIG`), nur Pfade/Bindungen, keine Geheimnisse.
- Vertrag: jede Ausgabe als `wb/v1`-Hülle (`schema`, `ok`, `data`, `warnings`, `error`, `meta`).

## 3. Führender Store und zweiter Rechner

- **Führender Store:** genau ein beschreibbarer Store auf dem Hauptrechner, Standard `C:\AI-OS-Wissensbasis`, Rolle `leader` im `MANIFEST.json`.
- **Zweiter Rechner:** erhält ein eingefrorenes `wb package` (readonly), das lokal wiederhergestellt wird. Der Spiegel hat die Rolle `mirror`; alle schreibenden Befehle werden mit Exit 3 abgelehnt.
- **Keine aktive SQLite-Datenbank über OneDrive:** `wb init`/`wb doctor` lehnen einen Store in OneDrive ab. Ein Paket ist eine Dateisammlung und wird vor Nutzung lokal eingespielt; es wird nie in OneDrive geöffnet.
- **Austauschzyklus:** `wb package create` im führenden Store → Paket kopieren (USB oder OneDrive als reines Archiv) → `wb restore --readonly` auf dem zweiten Rechner → Suche/Anzeige. Aktualisierung nur durch ein neues Paket, nie durch Live-Sync.

## 4. Zugriffsprüfung

Drei getrennte Prüfungen, keine davon allein ausreichend:

1. **Konfiguriertes Recht:** Bindung `read=1`, Quelle aktiv, Principal hat `read` (Owner implizit).
2. **Tatsächlicher Zugriff:** `os.access(path, R_OK|X_OK)` auf die Quelle, beim Import je Datei zusätzlich `R_OK`. Ergebnis wird mit Zeitpunkt und Methode gespeichert (`access_check`, `source_binding.observed_read`).
3. **Klassifikation:** Wissensraum und Vertraulichkeit. `mixed` verlangt `derive_cross_space` **und** Leserecht in beiden Räumen; es ersetzt aber nie die Prüfung 1 und 2.

Für abgeleitetes Wissen gilt: Lesen nur, wenn **jede** Belegfassung konfiguriert und tatsächlich lesbar ist. Für andere Principals als den lokalen Benutzer ist der OS-Zugriff nicht verifizierbar; sie werden im Pilot abgelehnt („externer Nachweis erforderlich"). Das ist bewusst konservativ.

## 5. Datenklassen (Backup-Priorität)

| Klasse | Inhalt | Reproduzierbar? | Sicherung |
| --- | --- | --- | --- |
| A | Originale in den Quellen | nein | separat, siehe [06_SICHERUNG.md](06_SICHERUNG.md) |
| B | Ledger: Herkunft, Fassungen, Notizen, Reviews, Rechte, Ereignisse | nein | `wb backup` (DB) |
| C | Extrahierter Text (`blobs/`) | im Prinzip aus Original + Extraktor | `wb backup` (Blobs) |
| D | FTS-Index (`index/`) | ja | **nicht** sichern; `index rebuild` |
| E | Exporte/Pakete | ja | bei Bedarf neu erzeugen |
| F | Rechnerkonfiguration | nein (aber ersetzbar) | separat, ohne Geheimnisse |

## 6. Testnachweis

`python -m unittest discover -s tests -p "test_*.py" -v`

```
Ran 16 tests in ca. 9,0 s
OK
```

Geprüfte Fälle: Init-Schutz (Temp/Repo), Import/Idempotenz/Quellenunverändertheit, Herkunft und Fassungen, Originalabruf inkl. Hash-Abweichung, Suche und Index-Rebuild-Gleichheit, Backup/Restore mit Notiz und Bestätigung, Read-only-Paket inkl. verweigerter Schreibbefehle, Blob-Korruptionserkennung, echte Zugriffsprüfung inkl. Verweigerung, `mixed`-Prüfung, Backup-Schutz vor Repositories, JSON-Vertrag, Belegstellen-Offsets, Belegüberholung, PDF-Seitenzuordnung, OCR als eigener Schritt, OCR-Ablehnung ohne Seiten, PDF-Seitenbegrenzung bei Textkürzung.

Synthetischer Lauf: 10 Quelldateien, 8 erfasste Elemente, 2 übersprungen (`.gitkeep`, PDF), 2 Extraktionsfehler (ungültiges UTF-8, leere Datei), 1 Office-`partial`, 1 Mail-`partial`; zweiter Import 0 neue Fassungen; Suche fand 5 Treffer (4 Belege + 1 Notiz).

Die PDF-Tests ersetzen den Worker durch eine kontrollierte Antwort und benötigen keine installierte Laufzeit. Die echten Text-/Scan-Läufe sind in [09_BELEGUEBERHOLUNG.md](09_BELEGUEBERHOLUNG.md) dokumentiert.

## 7. Befehlsübersicht

Alle Befehle werden aus `shared/tools/wissensbasis` ausgeführt (oder mit `PYTHONPATH` auf dieses Verzeichnis).

```powershell
# Einmalig
python -m wb init --root C:\AI-OS-Wissensbasis

# Quelle registrieren (Pfad bleibt in der lokalen Konfiguration)
python -m wb source add --id src-beispiel --name "Beispiel" --space business `
  --kind folder --path C:\Pfad\zur\Quelle --confidentiality internal `
  --organisation "AI-Consulting-OS" --authorization "nur lesend"

# Lesen und indexieren
python -m wb import --source src-beispiel --formats md,txt,html,docx,eml
python -m wb item list
python -m wb item show <item-id>
python -m wb search "Zielarchitektur Transformation"
python -m wb original <item-id> --out C:\Abruf
python -m wb index rebuild

# PDF-Text und OCR (isolierte Laufzeit erforderlich)
python -m wb import --source src-beispiel --formats pdf
python -m wb ocr <version-id>
python -m wb item show <item-id>
python -m wb search "Begriff aus dem Scan"

# Prüfen und sichern
python -m wb verify --access
python -m wb backup --out G:\AI-OS-Backups\2026-11\daily\2026-11-05\store\wissensbasis
python -m wb package create --out G:\Austausch\wissensbasis-paket
python -m wb restore --from G:\Austausch\wissensbasis-paket --root C:\AI-OS-Wissensbasis-ReadOnly --readonly

# Notizen und Bestätigungen
python -m wb note add --title "Prüfnotiz" --file C:\Notizen\pruefnotiz.md --space business
python -m wb review confirm <knowledge-version-id> --note "gesichtet"

# Zugriff
python -m wb acl check --source src-beispiel
python -m wb acl recheck
```

## 8. Bekannte Grenzen

- Nur der lokale Benutzer ist OS-verifiziert; Rollen/weitere Personen benötigen einen externen Zugriffsnachweis (nicht im Pilot).
- PDF/OCR: Text-PDFs bis 80 Seiten, OCR standardmäßig 8 Seiten pro Lauf, Text bis 1 500 000 Zeichen. Layout, Tabellen, Formeln, Bilder und Anmerkungen werden nicht ausgewertet; OCR ist erkennbar unsicher und bleibt `partial`. Ein OCR-Lauf markiert ausstehende Seiten ausdrücklich.
- PST/MSG und Anhänge werden nicht extrahiert.
- Office wird über XML gelesen (`partial`): Layout, Bilder, Formeln und Notizen können fehlen.
- Persistente Belegstellen (`citation`) für abgeleitete Aussagen sind vorbereitet, aber im lesenden Kern nicht erzeugt; Suchtreffer liefern berechnete Zeichenstellen, die gegen den gespeicherten Text geprüft werden.
- Keine Wissensverdichtung: keine Claims, Zusammenfassungen oder Entscheidungen aus Quellen.
- Keine semantische Suche: nur lexikalische FTS5-Suche mit AND/OR und BM25.
- Kein Hintergrund-Watcher: Aktualisierung nur durch `wb import`.
- Keine Löschung/Archivierung von Elementen über die CLI (Tombstones im Modell vorhanden).
- Kein Mehrbenutzerbetrieb, keine Cloud, keine Verschlüsselung ruhender Daten (NTFS-ACL).

## 9. Freigaben (Stand vor dem Pilotlauf)

Vor dem ersten Lauf mit echten Quellen waren zu bestätigen (der Profil-A-Lauf ist inzwischen erfolgt; die Punkte bleiben für einen Dauerbetrieb relevant):

1. **O1 Store-Pfad:** `C:\AI-OS-Wissensbasis` (oder anderer lokaler Pfad außerhalb von Repos/OneDrive).
2. **O2 Originalbytes:** Pilot speichert keine Originale; Originalabruf liest aus der Quelle und prüft den Hash. Für Dauerbetrieb später entscheiden.
3. **O9 Extraktor-Laufzeit:** Profil A (ohne PDF) ist die Abnahmebasis; die Laufzeit ist installiert und PDF/OCR an zwei PDFs geprüft. Profil B (alle 50 PDFs) bleibt ein eigener Lauf.
4. **Quellen und Rechte:** welche Ordner, welcher Raum, welche Vertraulichkeit, welche Ausnahmen.
5. **Sicherungsziel:** siehe [06_SICHERUNG.md](06_SICHERUNG.md).

Der Profil-A-Lauf wurde mit den in [05_PILOTIMPORT.md](05_PILOTIMPORT.md) definierten Abnahmekriterien ausgeführt; Ergebnis in [08_PILOTABNAHME.md](08_PILOTABNAHME.md). A17 und A20 bleiben offen.
