# 09 — Belegüberholung, PDF-Text und OCR: Nachweise

Stand: 2026-11-05 · Nachtrag zu [08_PILOTABNAHME.md](08_PILOTABNAHME.md) · Lesender Pilotkern · Keine Originale verändert · Keine Visualisierung.

Dieses Dokument belegt drei Dinge, die im Profil-A-Lauf vom 2026-11-05 noch offen waren:

1. die wörtlich dokumentierte Lücke bei **A17** und **A20**,
2. die **Überholung abhängigen Wissens und manueller Bestätigungen** durch eine neue Belegfassung, bei gleichzeitigem Erhalt der historischen Fassung,
3. **PDF-Text und OCR** als getrennte Verarbeitungsschritte in einer isolierten Laufzeit, einschließlich Seitenverweisen und ausdrücklicher Kennzeichnung unvollständiger Extraktion.

Die Profil-A-Abnahme in `08` bleibt unverändert gültig. Die hier beschriebenen Läufe sind zusätzliche Nachweise und verschieben die Profil-A-Schwellen nicht.

## 1. A17 und A20: wörtlicher Stand und offener Befund

Die beiden Kriterien stehen in [05_PILOTIMPORT.md](05_PILOTIMPORT.md), Abschnitt 4, unverändert so:

```text
| A17 | Abbruch/Wiederaufnahme | Import während Fixture-Lauf beenden | keine halbe Fassung; erneuter Lauf vollständig; verwaister Blob wird von gc entfernt |
| A20 | Rückbaubarkeit | Pilot-Store und Konfiguration löschen | Quellen unverändert; keine Repositories verändert; keine Reste außerhalb des dokumentierten Bereichs |
```

**Offener Befund:** Beide Kriterien sind **nicht geprüft** und damit **nicht bestanden**. Es gibt keinen kontrollierten Abbruch eines Imports (A17) und keine Löschung des Pilot-Stores mit anschließender Restprüfung (A20). Die Existenz von `wb gc` ist kein Nachweis für A17; das bewusste Aufbewahren des Pilot-Stores ist kein Nachweis für A20. Die Abnahme bleibt insoweit unvollständig.

Nicht geprüft ist damit insbesondere:

- ob ein Abbruch während des Imports eine halbe Fassung hinterlässt (erwartet: nein, weil Fassung und Extraktion in einer Transaktion entstehen),
- ob ein verwaister Text-Blob nach Abbruch tatsächlich von `wb gc` entfernt wird,
- ob nach Löschen von Store und Konfiguration keine Reste außerhalb des dokumentierten Bereichs bleiben.

Diese Punkte bleiben vor einer Dauerbetriebs-Freigabe ausdrücklich offen.

## 2. Überholung von Belegen, Wissen und Bestätigungen

### 2.1 Aufbau

Separater Store `C:\AI-OS-Pilot\supersession-store`, Quelle `C:\AI-OS-Pilot\supersession-source`, Konfiguration `C:\AI-OS-Pilot\supersession-config.json`. Die Quelle enthielt eine Datei `quelle.md` mit „Version eins“; daraus wurden eine belegpflichtige Wissensfassung (Claim) und eine unabhängige Notiz ohne Beleg abgeleitet und bestätigt. Danach wurde die Quelle auf „Version zwei“ geändert und erneut importiert.

Artefakte: `C:\AI-OS-Pilot\supersession-reports\` (Befehlsprotokolle, Vorher/Nachher-Zustand, Suche, Verify). Der Store ist ein Testartefakt und nicht der Produktions-Store.

### 2.2 Ergebnis

| Prüfung | Ergebnis |
| --- | --- |
| Alte Fassung | `ver-4c68becad1061772eff58dce`, `seq_no=1`, `is_current=false`, `superseded_by=ver-fb3667f36910fe597ebebc29` |
| Neue Fassung | `ver-fb3667f36910fe597ebebc29`, `seq_no=2`, `is_current=true` |
| Abhängiger Claim | `knw-8818626b2f64465e9dbe5664243c2327`, Fassung `knv-54cae938c5854185bd7b8fd6d3fa63b9`, Zustand **`confirmation_stale`** |
| Bestätigung des Claims | Entscheidung bleibt `confirmed`, erhält aber `invalidated_at=2026-11-05T13:13:04.053345Z`, `invalidated_by_version_id=ver-fb3667f36910fe597ebebc29` und einen konkreten Grund |
| Unabhängige Notiz | `knw-13a28ed466814c749e77c8d4244efba4`, Zustand bleibt **`confirmed`** (kein Belegbezug) |
| Historischer Beleg | `wb evidence ver-4c68becad1061772eff58dce` liefert `is_current=false`, `superseded_by=...`, den alten Text „Version eins mit Quellenlage A.“ und den Hinweis auf die überholte Wissensfassung |
| Suche | findet die Wissensfassung mit `review_state=confirmation_stale` und **beide** Fassungen des Belegs; die alte Fassung bleibt also auffindbar |
| Integrität | `wb verify` → `ok=true` |

Der Zustand „bestätigt“ wird damit nicht stillschweigend auf eine neue Beleglage übertragen. Die Bestätigung bleibt als historisches Ereignis erhalten, ist aber sichtbar überholt; abhängiges Wissen verlangt erneut eine Prüfung. Die alte Fassung samt Text bleibt abrufbar. Für unbestätigtes abhängiges Wissen ist `needs_review` bereits bei Erstellung gesetzt; der Unit-Test prüft zusätzlich, dass ein zweiter, unbestätigter Claim nach der Überholung review-pflichtig bleibt und seine Herkunft behält.

### 2.3 Grenzen dieses Nachweises

- Nur ein Claim und eine unabhängige Notiz im Integrationslauf; der Unit-Test ergänzt einen unbestätigten Claim. Keine mehrstufige Wissenskette.
- Die Quelle war eine synthetische Testdatei, kein reales Dokument.
- Es gab keine reale Änderung an einem Originalbestand; die Originale des Profil-A-Laufs blieben unberührt.
- Die Suche liefert alte und neue Fassung nebeneinander. Das ist für Belegprüfung erwünscht, erfordert in einer Oberfläche aber eine klare Kennzeichnung „historisch“.

## 3. PDF-Text und OCR

### 3.1 Isolierte Laufzeit

PDF und OCR laufen **nicht** im Standard-Python des Kerns, sondern in einer separat installierten Laufzeit unter `%LOCALAPPDATA%\AI-OS\Wissensbasis\runtime`. Der Kern bleibt damit ohne Fremdpakete installierbar. Die Laufzeit wird mit `setup-extractor.ps1` erzeugt; sie lädt uv 0.9.9 und Python 3.12.12 herunter, legt eine virtuelle Umgebung an und installiert die Paketvorgaben aus `requirements-extract.txt`. Es werden keine Dokumente hochgeladen.

Geprüfte Versionen: `pypdf 6.21.4`, `pypdfium2 5.14.0`, `rapidocr-onnxruntime 1.4.4`, `Pillow 12.3.0`. Der Einrichtungsvorgang endet mit `EXTRACTOR_RUNTIME_READY` und `EXTRACTOR_READY`.

Im Import ist PDF nur enthalten, wenn `--formats pdf` ausdrücklich angegeben wird. OCR startet **nie** automatisch beim Import, sondern nur über `wb ocr <version-id>`.

### 3.2 Text-PDF

Getestet mit einer Kopie von `Positionspapier_ZP-Napeduv_Aug_26.pdf` in `C:\AI-OS-Pilot\pdf-pilot\source\text-positionspapier.pdf`:

| Wert | Ergebnis |
| --- | --- |
| Element/Fassung | `itm-eb20e4e3cb4e6cb4e2fbdbab` / `ver-0c33534ed2fbeda2d0b7dd98` |
| Extraktor | `pdf-pypdf`, Status `partial` (bewusst: Layout, Tabellen und Bilder werden nicht ausgewertet) |
| Umfang | 4 Seiten, 6 310 Zeichen |
| Seitenmetadaten | 4 Seiten mit Start-/Endoffset und Zeichenzahl; keine OCR ausstehend |
| Suche | `Napeduv` liefert Treffer mit Seite 1, 2 und 4; die Zeichenstelle liegt jeweils im extrahierten Text |
| Integrität | `verify` prüft die Seitenmetadaten (`pages_consistent=true`) |

### 3.3 Scan-PDF mit OCR

Getestet mit einer Kopie von `Schaer_Offerte_2026-08-12_sch-297_Scan_20261007_152232.pdf` in `C:\AI-OS-Pilot\pdf-pilot\source\scan-offerte.pdf`:

Die PDF-Messwerte sind zusätzlich in `C:\AI-OS-Pilot\pdf-pilot\result.json` zusammengefasst.

| Wert | Ergebnis |
| --- | --- |
| Element/Fassung | `itm-1237f944c45f4dfb41061a6c` / `ver-b848939040f754643ff7dbe3` |
| Import | 18 Seiten; Textschicht praktisch leer; **18 Seiten OCR ausstehend**; Status `partial` |
| OCR-Lauf 1 | Seiten 1–8 erkannt; Seiten 9–18 bleiben ausstehend |
| OCR-Lauf 2 | Seiten 9–16 erkannt; Seiten 17–18 bleiben ausstehend |
| OCR-Lauf 3 | Seiten 17–18 erkannt; danach 18/18 Seiten mit OCR-Text |
| Endtext | 16 791 Zeichen; Extraktor `pdf-ocr`, Status `partial` |
| Seitenmetadaten | 18 Seiten, jede mit `ocr=true`, Start-/Endoffset und Zeichenzahl |
| Suche | `solarstrom` liefert 10 Treffer, u. a. auf Seite 2, 4 und 7; die Zeichenstelle liegt im OCR-Text |
| Wiederholung | weiterer OCR-Lauf endet mit `ocr_none` („Keine ausstehenden Seiten fuer OCR“) und Exit 2 |
| Integrität | `verify` → `ok=true`, `pages_consistent=true` |

Die OCR-Erkennung ist brauchbar, aber sichtbar unsicher: Zahlen, Firmenname und Layout werden teils fehlerhaft erkannt. Der Status bleibt deshalb `partial` mit dem Grund „Erkennungsunsicherheit und Layoutgrenzen moeglich“. Es wird keine vollständige Auswertung behauptet.

### 3.4 Unvollständige Extraktion wird ausdrücklich markiert

Ein eigener Lauf in `C:\AI-OS-Pilot\pdf-limit` zeigt das OCR-Limit pro Aufruf:

- 18 Seiten angefordert,
- Seiten 1–8 erkannt,
- Seiten 9–18 als ausstehend gemeldet,
- Grund: „OCR ausgefuehrt auf Seiten 1, 2, 3, 4, 5, 6, 7, 8; … OCR-Limit pro Lauf erreicht, ausstehend: 9, 10, … 18“,
- Status `partial`, `verify` ok.

Damit ist unvollständige Extraktion nicht als Erfolg getarnt. Die verbleibenden Seiten können mit weiteren `wb ocr`-Läufen nachgezogen werden; sie sind bis dahin weder durchsuchbar noch als erkannt markiert.

### 3.5 Seitenbezug im Suchtreffer

Der Suchtreffer enthält jetzt `page` (die Seite, auf der die belegte Zeichenstelle liegt) zusätzlich zu `citation.start`/`citation.end`. Die Seite wird aus den gespeicherten Seitenoffsets und der tatsächlichen Trefferstelle berechnet, nicht aus dem Anfang des Textabschnitts. Ein Treffer in einem Abschnitt, der über eine Seitengrenze reicht, wird damit der richtigen Seite zugeordnet.

### 3.6 Originale, Backup und Wiederherstellung

- Die beiden Quelldateien sind Kopien. Ihre SHA-256-Werte stimmen mit den Originalen überein; die Wissensbasis hat sie nur gelesen.
- `wb backup` und `wb restore` in `C:\AI-OS-Pilot\pdf-pilot\restore` erhalten Seitenmetadaten und Seitensuche; `verify` ist ok, `solarstrom` liefert im wiederhergestellten Store 10 Treffer mit Seite 4 und Status `partial`.
- Der Store enthält weiterhin **keine Originalbytes**; gespeichert sind Metadaten, Text und Seitenoffsets.

## 4. Testnachweis

`python -m unittest discover -s tests -p "test_*.py" -v` → **16 Tests, alle bestanden** (Laufzeit ca. 9,0 s). Neu gegenüber dem Profil-A-Stand:

- `test_pdf_text_import_keeps_page_references`
- `test_pdf_ocr_is_explicit_step_and_keeps_old_extraction`
- `test_pdf_without_pages_rejects_ocr`
- `test_pdf_page_metadata_is_clamped_at_text_limit`
- `test_evidence_supersession_marks_knowledge_and_keeps_history`

Die Tests laufen ohne installierte Extraktor-Laufzeit: Der PDF-Worker wird für die Unit-Tests durch eine kontrollierte Antwort ersetzt; die echten PDF-/OCR-Läufe sind die oben dokumentierten Integrationsläufe.

## 5. Ausdrücklich nicht geprüft oder nicht enthalten

- **A17 und A20** (siehe Abschnitt 1).
- **Profil B mit allen 50 PDFs.** Getestet sind zwei PDFs; das sind keine 50 und keine Abdeckungsquote im Sinne von B1/B2.
- **Schutz vor Festplattenausfall.** Backup, Restore und Testkopien liegen auf `C:`. Wiederherstellbarkeit ist belegt, Ausfallschutz nicht.
- **Reale ACL-Verweigerung.** Weiterhin nur über `os.access`-Simulation im Test geprüft.
- **Semantische Suche, Embeddings, automatische Zusammenfassungen und Wissensverdichtung.** Ausdrücklich spätere, offene Funktionen.
- **Grenzen der PDF-Verarbeitung:** Text-PDFs bis 80 Seiten, OCR standardmäßig 8 Seiten pro Lauf, Gesamttext bis 1 500 000 Zeichen; Layout, Tabellen, Formeln, Bilder und Anmerkungen werden nicht ausgewertet. OCR-Qualität hängt von Scanqualität und Modell ab.
- **Produktions-Store** `C:\AI-OS-Wissensbasis` wurde nicht angelegt.
- **Visualisierung/Themenlandkarte** wurde nicht verändert.

## 6. Empfehlung

Die Nachweise stützen den lesenden Kern, ersetzen aber die offenen Abnahmepunkte nicht. Vor einer Dauerbetriebs-Freigabe sollten mindestens A17 und A20 nachgeholt, ein echtes Sicherungsziel außerhalb von `C:` festgelegt und der Umgang mit OCR-Qualität sowie historischen Fassungen in einer Oberfläche entschieden werden. Profil B bleibt ein eigener, noch nicht durchgeführter Lauf.
