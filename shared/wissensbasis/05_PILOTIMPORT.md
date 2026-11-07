# 05 — Begrenzter Pilotimport

Stand: 2026-11-05 · Profil A ausgeführt · PDF/OCR-Nachtrag geprüft · A17/A20 offen.

**Umsetzungsstand:** Der lesende Pilotkern ist implementiert und mit synthetischen Daten getestet (**16 Tests bestanden**, siehe [07_PILOTKERN.md](07_PILOTKERN.md)). **Profil A wurde am 2026-11-05 mit echten Quellen ausgeführt.** Ergebnis und Abnahmestatus: [08_PILOTABNAHME.md](08_PILOTABNAHME.md). PDF-Text wurde an einem Text-PDF, OCR an einem Scan geprüft, nicht mit allen 50 PDFs; A17 und A20 bleiben ungeprüft. Details: [09_BELEGUEBERHOLUNG.md](09_BELEGUEBERHOLUNG.md).

## 1. Ziel des Piloten

Der Pilot belegt an einem kleinen, echten Bestand, dass die Wissensbasis die drei Ziele praktisch trägt:

- **Sammeln:** Quellen werden vollständig registriert, gelesen und versioniert, ohne Originale zu verändern.
- **Finden:** ein belegter Suchindex liefert reproduzierbare Treffer und lässt sich nach Löschung vollständig wiederherstellen.
- **Vertrauen:** Herkunft, Fassung, Rechte und manuelle Bestätigung sind prüfbar; unbekannte Zustände bleiben sichtbar.

Er ist **kein** Produktivimport, keine Migration und keine Oberflächenanbindung.

## 2. Umfang

### 2.1 Arbeitsverzeichnisse

| Zweck | Pfad | Lebensdauer |
| --- | --- | --- |
| Pilot-Store | `C:\AI-OS-Wissensbasis-Pilot` | bis zur Abnahme; danach ausdrücklich aufbewahren oder löschen |
| Pilotarbeitsordner | `C:\AI-OS-Pilot\` mit `fixtures/`, `expected/`, `reports/` | bis zur Abnahme |
| Lokale Konfiguration | `%LOCALAPPDATA%\AI-OS\Wissensbasis\config.json` | dauerhaft (Rechnerbindung) |
| Logs | `%LOCALAPPDATA%\AI-OS\Wissensbasis\logs\` | 30 Tage |

Der Pilot-Store liegt **außerhalb** aller Git-Repositories, nicht in OneDrive und nicht in `%TEMP%`.

### 2.2 Quellen (nur lesend)

| ID | Quelle | Elemente | Größe | Raum | Rechte |
| --- | --- | ---: | ---: | --- | --- |
| `src-consulting-zp-sources` | `AI-Consulting-OS/07_ENGAGEMENTS/active/ENG-2026-002-ZP-Systemlandschaft/sources` | 17 (13 PDF, 3 MD, 1 XLSX) | 4.7 MB | Geschäft | lesen, ableiten |
| `src-consulting-taxa-sources` | `AI-Consulting-OS/07_ENGAGEMENTS/active/ENG-2026-001-TAXA-Natural-Exit/sources` | 6 (2 PDF, 4 MD) | 0.3 MB | Geschäft | lesen, ableiten |
| `src-private-fg-documents` | `AI-Private-OS/cases/flurgenossenschaft-gruenaustrasse/documents` | 69 (35 PDF, 22 TXT, 8 DOCX, 2 MD, 1 PPTX, 1 `.gitkeep`) | 18.7 MB | Privat | lesen, ableiten |
| `src-pilot-fixtures` | `C:\AI-OS-Pilot\fixtures` | 8 synthetische Dateien | < 0.1 MB | Geschäft | lesen (Dateien werden nur durch das Testskript geändert, nicht durch die Wissensbasis) |
| `src-pilot-missing` | `C:\AI-OS-Pilot\missing` (existiert absichtlich nicht) | 0 | 0 | Geschäft | lesen |

Alle Quellen sind schreibgeschützt gebunden (`write=0`), auch die Fixtures. Nur das Testskript verändert Fixture-Dateien außerhalb der Wissensbasis; die Wissensbasis selbst schreibt nie in Quellen (`write_back=false`).

**Scanumfang:** 100 Dateien (92 reale + 8 Fixtures). Profil A erfasst 49 und überspringt 51 mit Grund (50 PDFs außerhalb des Profils, 1 `.gitkeep`). Profil B erfasst 99 und überspringt 1 (`.gitkeep`).

### 2.3 Zwei Profile

**Profil A — verpflichtend, ohne Zusatzlaufzeit.** Import mit Format-Allowlist (MD, TXT, CSV, JSON, HTML, DOCX, XLSX, PPTX); PDFs werden nicht erfasst, sondern mit Grund „außerhalb Pilotprofil A“ übersprungen.

- 41 reale Elemente: 22 TXT, 8 DOCX, 2 MD (Privat) + 3 MD, 1 XLSX (ZP) + 4 MD (TAXA) + 1 PPTX (Privat); 1 `.gitkeep` wird als technische Datei übersprungen.
- 8 Fixtures: `notiz.md`, `text.txt`, `tabelle.csv`, `daten.json`, `seite.html`, `duplikat.md` (gleicher Inhalt wie `notiz.md`), `ungueltig.md` (ungültiges UTF-8), `leer.md` (0 Bytes).
- **49 Elemente, ca. 3 MB.**
- Extraktionsstatus: TXT/MD/CSV/JSON/HTML `full`; DOCX/XLSX/PPTX `partial` (XML-Text ohne Layout, Bilder, Formeln) mit Grund.

**Profil B — optional, 50 PDFs.** Die isolierte Extraktor-Laufzeit ist implementiert; PDF-Text und OCR wurden an **zwei** PDFs geprüft (ein Text-PDF, ein Scan mit 18 Seiten). Der vollständige Profil-B-Lauf mit allen 50 PDFs wurde **nicht** durchgeführt. Der Import kann PDFs über `--formats pdf` erfassen; OCR ist ein eigener Schritt (`wb ocr <version-id>`) und startet nie automatisch. Ohne installierte Laufzeit entstehen Fassungen mit Status `unsupported` und Grund.

- **99 Elemente, ca. 24 MB** (bei vollständigem Profil-B-Lauf).
- Status: `full` bei extrahierbarem Text, `partial` bei OCR-/Layoutgrenzen, `failed` nur mit Grund. Wird Profil B nicht freigegeben, werden die PDFs nicht erfasst, sondern mit Grund übersprungen.

Profil A ist die Abnahmebasis. Profil B hat eigene Kriterien und verschiebt die Abnahme nicht.

### 2.4 Ausdrücklich ausgeschlossen

- Kein Import der übrigen 12 600 Dateien, des Mailarchivs, von PST/OST oder Cloud-/Webquellen.
- Keine Anhangs-Extraktion, keine KI-Ableitung, keine OCR ohne O9-Freigabe.
- Kein Zurückschreiben in Quellen (W2), kein Veröffentlichen in Repositories.
- Keine Änderung an Themenlandkarte, Repositories oder Originalen.
- Keine Oberfläche; Bedienung ausschließlich über CLI.

## 3. Ablauf

### 3.1 Vorbedingungen

1. O1 (Store-Pfad), O5 (Prüferrolle), O9 (Extraktor-Laufzeit) und O10 (Sicherungsziel) entschieden. O2 ist für den Pilotkern festgelegt: **keine Originalkopien im Store**.
2. Kern aus `shared/tools/wissensbasis` verfügbar (nur Standardbibliothek) und `python -m wb --version` geprüft.
3. `C:\AI-OS-Pilot\fixtures` mit den acht Dateien angelegt (synthetisch, im Dokument beschrieben).
4. Vorher-Hashes aller realen Quelldateien in `C:\AI-OS-Pilot\reports\source-before.json` festgehalten.
5. Konfiguration mit den drei realen Bindungen, der Fixture-Bindung und der Missing-Bindung; `write_back=false`.

### 3.2 Schritte

Alle Befehle werden aus `shared/tools/wissensbasis` ausgeführt (oder mit `PYTHONPATH` auf dieses Verzeichnis).

| Nr. | Schritt | Befehl (implementiert) | Erwartung |
| --- | --- | --- | --- |
| 1 | Init | `python -m wb init --root C:\AI-OS-Wissensbasis-Pilot` | Manifest, DB, Schema, Pfadprüfung |
| 2 | Quellen | `python -m wb source add …` × 5 | IDs, Herkunft, Rechte, Bindungen |
| 3 | Probe | `python -m wb source probe` | 4× `reachable`, 1× `unreachable` (Missing-Quelle), Fingerprints stimmen |
| 4 | Vorschau | `python -m wb import --source … --dry-run --formats md,txt,csv,json,html,docx,xlsx,pptx` | 41 + 8 erfasst; 51 übersprungen (50 PDF, 1 `.gitkeep`); 0 Schreibvorgänge |
| 5 | Import | `python -m wb import --all --formats …` | 49 Elemente, Status wie 2.3, Laufzeit ≤ 5 min |
| 6 | Prüfung | `python -m wb verify --access` | Exit 0, keine Abweichung |
| 7 | Suche | `python -m wb search …` | 10 feste Abfragen, Goldtreffer |
| 8 | Rechte | gemischte Notiz anlegen; `python -m wb acl check --knowledge … --principal reader-business`; `acl recheck` | `mixed` allein genügt nicht; fremder Principal ohne OS-Nachweis wird abgelehnt |
| 9 | Bestätigung | `python -m wb review confirm …`; `review reject`; falscher Basis-Hash | `confirmed`/`rejected`; Konflikt bei falscher Basis; persistiert nach Backup/Restore |
| 10 | Versionierung | Fixture ändern, importieren | genau 1 neue Fassung, alte bleibt; zweiter Import 0 neue |
| 11 | Index | Index löschen, `python -m wb index rebuild` | identische Goldtreffer, ≤ 60 s |
| 12 | Sicherung | `python -m wb backup --out …`; `restore --root <temp>`; `verify` | DB, Text, Notiz und Bestätigung wiederhergestellt |
| 13 | Austausch | `python -m wb package create --out …`; `restore --readonly` | Spiegel liest/sucht, verweigert Schreiben und Originalabruf |
| 14 | Aufräumen | Pilot-Store behalten oder löschen; Quellenhash vergleichen | Originale unverändert |

### 3.3 Goldabfragen

Zehn Abfragen mit erwarteten Treffer-IDs, die vor dem ersten Indexbau festgelegt und in `C:\AI-OS-Pilot\expected\search-golden.json` gespeichert werden. Beispiele: „Dashboard Zählregeln“, „Grobplan Sanierung“, „Traktandenliste 2025“, „Photovoltaik Speicher“, „Quellenregister“, „Statuten“, „Protokoll HV“, „Budget“, „Steuererklärung“, „Abteilungsinfo“. Die Golddatei enthält nur IDs und Ränge, keine Dokumenttexte.

## 4. Abnahmekriterien (Profil A)

Jedes Kriterium ist bestanden, wenn der genannte Nachweis vorliegt. Ein einzelnes `fail` verhindert die Abnahme.

| ID | Kriterium | Nachweis | Schwelle |
| --- | --- | --- | --- |
| A1 | Vollständigkeit | Importbericht + Abgleich mit Verzeichnisliste | 49/49 erfasste Elemente; 51 übersprungen mit Grund (50 PDF außerhalb Profil A, 1 `.gitkeep`); 0 unbekannte Auslassungen |
| A2 | Originale unverändert | `source-before.json` vs. `source-after.json` (SHA-256 je Datei) | 100 % identisch; keine Datei verschoben, umbenannt oder gelöscht |
| A3 | Idempotenz | zweiter Importlauf | 0 neue Elemente, 0 neue Fassungen, 49 unverändert, gleiche Hashes |
| A4 | Extraktionswahrheit | Statusverteilung | MD/TXT/CSV/JSON/HTML `full`; Office `partial` mit Grund; PDF `skipped` mit Grund; 0 `full` für nicht vollständig gelesene Inhalte; 0 stille Fehler |
| A5 | Herkunft vollständig | `item show` / `verify` | jede Fassung: Quelle, Bindung, SHA-256, Erfassungszeit, Extraktorversion; `original_stored=0` nachgewiesen |
| A6 | Zitate | Suche | 100 % der Suchauszüge stimmen an der angegebenen Zeichenstelle; keine erfundenen Auszüge |
| A7 | Rechte | Rechte-Testfälle | Owner nur mit tatsächlichem OS-Zugriff; `reader-business` wird ohne externen Nachweis abgelehnt; gemischte Notiz erfüllt nur mit `derive_cross_space` **und** beiden Räumen; Suchtreffer verweigerter Quellen werden gefiltert und gezählt |
| A8 | Bestätigung | Review-Ablauf | `confirmed`/`rejected` nur mit Prüfer; falscher Basis-Hash → Konflikt; Bestätigung übersteht Backup/Restore. Die Überholung durch eine neue Belegfassung ist im Nachtrag [09_BELEGUEBERHOLUNG.md](09_BELEGUEBERHOLUNG.md) geprüft. |
| A9 | Versionierung | Fixture-Änderung | genau 1 neue Fassung, `seq_no` +1, `supersedes` gesetzt; unveränderte Dateien 0 neue Fassungen |
| A10 | Dedupe | Fixture-Duplikat | 1 Blob für identische Bytes, 2 Elemente, 2 Fassungen mit gleichem `content_hash` |
| A11 | Fehlerzustände | ungültiges UTF-8, leere Datei | Element erfasst, Extraktion `failed` mit Grund (leer bzw. ungültiges UTF-8); kein Absturz; Wiederholung stabil |
| A12 | Suche belegt | Goldabfragen | alle 10 Abfragen: erwartete IDs im erwarteten Rang; jeder Treffer mit Quelle/Element/Fassung/Stelle; p95 ≤ 300 ms (20 Wiederholungen) |
| A13 | Index wiederherstellbar | Index löschen, `rebuild` | identische Treffer und Ränge; Build ≤ 60 s; `verify --index` ok; Indexgröße berichtet |
| A14 | Sicherung/Wiederherstellung | `python -m wb backup`, `python -m wb package create`, `restore` in neuen Store | `verify` ok; Zählungen identisch; Notiz und Bestätigung erhalten; Suche nach Rebuild identisch |
| A15 | Trennung/Sauberkeit | Prüfung | keine Store-Datei in einem Repository; `git status` der Repositories unverändert (außer Entwurfsdokumenten); `tmp/` leer; keine Geheimnisse in Store/Logs; Paket liegt nicht als aktive DB in OneDrive |
| A16 | Quelle nicht erreichbar | Missing-Quelle binden; Fixture-Bindung temporär auf fehlenden Pfad zeigen | Missing-Quelle `unreachable` mit letztem Erfolg `unknown`; Fixture-Quelle `unreachable`, letzter Erfolg bleibt erhalten; kein Absturz; nach Rückkonfiguration wieder `reachable` |
| A17 | Abbruch/Wiederaufnahme | Import während Fixture-Lauf beenden | keine halbe Fassung; erneuter Lauf vollständig; verwaister Blob wird von `gc` entfernt |
| A18 | Vertrag | `--json` aller Befehle | `schema: wb/v1`, stabile Felder, unbekannte Werte als `unknown` mit Grund, Exit-Codes korrekt (Verify-Fehler = 5) |
| A19 | Leistung/Umfang | Messbericht | Import ≤ 5 min; `verify` ≤ 60 s; Store ≤ 100 MB; Index ≤ 30 MB |
| A20 | Rückbaubarkeit | Pilot-Store und Konfiguration löschen | Quellen unverändert; keine Repositories verändert; keine Reste außerhalb des dokumentierten Bereichs |
| A21 | Abgrenzung | Befehls- und Ausgabeprüfung | keine semantische Suche, keine Embeddings, keine generierten Zusammenfassungen/Claims; diese Funktionen sind ausdrücklich nicht Teil des Pilotkerns |

## 5. Abnahmekriterien für Profil B (noch nicht durchgeführt)

Der PDF-Adapter ist inzwischen implementiert und an zwei PDFs geprüft (Text-PDF und Scan mit OCR; siehe [09_BELEGUEBERHOLUNG.md](09_BELEGUEBERHOLUNG.md)). **Profil B mit allen 50 PDFs ist damit nicht bestanden**; die B-Kriterien bleiben ungeprüft.

| ID | Kriterium | Schwelle |
| --- | --- | --- |
| B1 | PDF-Registrierung | 50/50 PDFs als Elemente erfasst, 0 ausgelassen |
| B2 | Extraktionsabdeckung | ≥ 45/50 PDFs mit Text (full oder partial mit Grund); ≤ 5 `failed`, jeder mit konkretem Grund |
| B3 | Belegbarkeit | 5 vorab benannte Textstellen aus PDFs sind über Zitat + Seite belegbar und `verify`-geprüft |
| B4 | Laufzeit | ≤ 30 s pro PDF im Durchschnitt, Gesamtlauf ≤ 20 min |
| B5 | Keine Scheinvollständigkeit | OCR-/Layoutgrenzen als `partial` mit Grund; keine Behauptung vollständiger Auswertung |

Ohne O9-Freigabe gilt Profil B als „nicht durchgeführt“: Die 50 PDFs werden nicht erfasst, sondern im Importbericht als „außerhalb Pilotprofil A“ übersprungen ausgewiesen. A1, A4 und A19 beziehen sich dann ausschließlich auf die 49 Elemente aus Profil A. Die 50 Profil-B-PDFs sind damit ausdrücklich **nicht geprüft**, nicht „erfolgreich“. Unabhängig davon wurden zwei einzelne PDFs für den PDF/OCR-Nachweis in [09_BELEGUEBERHOLUNG.md](09_BELEGUEBERHOLUNG.md) verwendet.

## 6. Testfälle (Nachweisform)

| Nr. | Test | Artefakt |
| --- | --- | --- |
| TC-01 | Init verweigert Store in Repo/`%TEMP%`/OneDrive; akzeptiert korrekten Pfad | `init-report.json` |
| TC-02 | Quellenregistrierung, Fingerprint, Rechte | `sources.json` (Store-Export), `probe.json` |
| TC-03 | Dry-Run ohne Schreibvorgänge (Store-Hash vor/nach) | `dry-run.json` |
| TC-04 | Import Profil A | `import-report.json` |
| TC-05 | Zweiter Import | `import-report-2.json` |
| TC-06 | Fixture-Änderung | `version-change.json` |
| TC-07 | Duplikat | `dedupe-report.json` |
| TC-08 | Fehlerhafte Dateien | `extraction-errors.json` |
| TC-09 | Herkunft/Zitate | `verify-full.json` |
| TC-10 | Rechte/mixed | `acl-report.json` |
| TC-11 | Bestätigung/Überholung | `review-report.json` |
| TC-12 | Goldsuche | `search-golden.json` + Messwerte |
| TC-13 | Index löschen/neu bauen | `index-build.json` |
| TC-14 | Backup/Restore | `restore-report.json` |
| TC-15 | Trennung/Sauberkeit | `separation-check.json` |
| TC-16 | Quelle offline (Missing-Quelle, Bindung temporär ungültig) | `source-offline.json` |
| TC-17 | Abbruch/Wiederaufnahme | `resume-report.json` |
| TC-18 | Vertrag/Exit-Codes | `contract-check.json` |
| TC-19 | Rückbau | `rollback-report.json` |

Die Artefakte liegen ausschließlich unter `C:\AI-OS-Pilot\reports` und enthalten keine Inhalte, nur IDs, Hashes, Zähler, Zeiten und Fehlergründe.

## 7. Messwerte

Zu erfassen: Laufzeit je Phase, Elemente/Minute, Extraktionsdauer je Typ, Store-Größe (DB/Blobs/Index), Trefferzahlen und p95-Latenz der 10 Goldabfragen, Anzahl Fassungen/Belege/Zitate, Anzahl Bestätigungen und Überholungen, Anzahl Rechteprüfungen, Anzahl Fehler nach Typ, Größe der Sicherung.

## 8. Abbruchkriterien

Der Pilot wird sofort abgebrochen und berichtet, wenn:

- eine Originaldatei verändert, verschoben oder gelöscht wurde (Hash-Abweichung),
- eine Store-Datei in einem Repository landet,
- Geheimnisse oder vollständige private Inhalte in Logs, Berichten oder Exporten auftauchen,
- eine Extraktion als `full` gemeldet wird, obwohl Inhalt fehlt,
- der Index-Rebuild von den Goldtreffern abweicht,
- `verify --full` Integritätsfehler meldet, die nicht sofort erklärbar sind,
- ein Rechte-Test private Inhalte an `reader-business` liefert,
- der Zeitrahmen um mehr als 100 % überschritten wird.

## 9. Aufwand (Schätzung)

| Paket | Inhalt | Aufwand |
| --- | --- | --- |
| Kern | Schema, Blob-Store, CLI, Extraktoren (Text/Office), Ledger, Rechte, Reviews, Index | 6–9 Arbeitstage |
| Betrieb | verify, backup/restore, gc, Export, Goldtests | 2–3 Arbeitstage |
| Pilot | Fixtures, Läufe, Berichte, Abnahme | 2–3 Arbeitstage |
| Reserve | Fehlerkorrekturen, Wiederholungen | 2–4 Arbeitstage |
| **Gesamt** | | **12–19 Arbeitstage** |

Die Schätzung ist eine Planungsannahme, keine Zusage. Profil B (alle 50 PDFs) ist nicht enthalten; der nachträgliche PDF/OCR-Grundlauf war ebenfalls nicht Teil der ursprünglichen Schätzung.

## 10. Ergebnisse und Entscheidung

Nach dem Pilot liegen vor: bestandene/nicht bestandene Kriterien A1–A20 (und ggf. B1–B5), Messwerte, offene Punkte und eine Empfehlung zu Store-Pfad, Aufbewahrung, Rechteschnittstelle und nächster Ausbaustufe. Erst danach wird über Dauerbetrieb, Mail-Adapter, Oberflächenanbindung und Schreibkanal entschieden.

Der Pilot verändert keine Originale und keine Repositories. Er kann durch Löschen des Pilot-Stores und der lokalen Konfiguration vollständig zurückgenommen werden; die Quellen bleiben unberührt.
