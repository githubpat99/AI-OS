# 10 — Flurgenossenschaft-Pilot: RAW → Ingestion → Synthese → Test

Stand: 2026-11-05 · Lesender Pilotkern · Keine Originale verändert · Themenlandkarte als Client ergänzt · Keine Bestätigung von Wissensseiten.

## 1. Ablage und Architektur

Der Pilot verwendet die bestehende Trennung der Wissensbasis:

| Ebene | Ablage | Rolle |
| --- | --- | --- |
| RAW | `C:\AI-OS-Pilot\flurgenossenschaft\RAW` | externe Originalablage (Datenklasse A), byte-identische Kopien, außerhalb von Store und Repository |
| Store | `C:\AI-OS-Wissensbasis-Flurgenossenschaft-Pilot` | Leader-Store mit Ledger, extrahiertem Text und Index; **keine Originalbytes** |
| Konfiguration | `C:\AI-OS-Pilot\flurgenossenschaft\config.json` | lokale Bindung `src-fg-raw`, keine Geheimnisse im Store |
| Synthese-Arbeitsfassungen | `C:\AI-OS-Pilot\flurgenossenschaft\synthesis` | Markdown-Entwürfe; kanonisch im Store als `knowledge`/`knowledge_version` |
| Berichte | `C:\AI-OS-Pilot\flurgenossenschaft\reports` | Import-, OCR-, Synthese- und Testergebnisse |

Damit bleiben Originale, extrahierter Text und Wissensseiten getrennt. Die Originale im Case `AI-Private-OS/cases/flurgenossenschaft-gruenaustrasse` wurden nur gelesen.

## 2. Schritt 1 — RAW

- **12 Originalquellen** ausgewählt: Statuten, drei HV-Protokolle, Kostenschätzung, Koordinationssitzung, Budget 2024/25, zwei Traktandenstände 2026, Präsidentenbericht 2025, NRP-Honorarofferte und Retentionsberechnung.
- Kopie mit `shutil.copy2`, danach erneute SHA-256-Prüfung: **12/12 byte-identisch**, keine Quelle verändert.
- Herkunft: `RAW\manifest.json` (`fg-raw/v1`) mit Quellpfad, RAW-Pfad, Größe, SHA-256 und Kopierzeitpunkt.

## 3. Schritt 2 — Ingestion

- Import mit `--formats pdf,txt,docx`: **12 Elemente, 12 Fassungen, 0 failed, 0 unsupported**.
- 13 Seiten ohne Textschicht (Statuten 12, Kostenschätzung Seite 8) wurden in drei expliziten OCR-Läufen nachgezogen; danach **0 ausstehende OCR-Seiten**.
- **Keine Datei vollständig unlesbar.** Nicht maschinell rekonstruiert bzw. eingeschränkt: Layout/Tabellen (DRV-008, DRV-018, Protokolle), Pläne/Bilder/Unterschriften (DRV-008 S. 8, DRV-045), DOCX-Bilder/Formeln (DRV-011), nativer Tabellenstand (DRV-061) sowie OCR-Fehler und fehlende Wortabstände (DRV-045).
- Ergebnis: 106 Indexabschnitte, Store 0,94 MB, `verify ok`.
- Details: `reports/SCHRITT-1-RAW.md`, `reports/SCHRITT-2-INGEST.md`.

## 4. Testfragen — vor der Synthese

Am 2026-11-05, nach Ingestion und **vor** dem Anlegen der Wissensseiten, wurden 11 Fragen festgelegt (`TESTFRAGEN.md`; Dateizeit 14:55:37, erste Synthesefassung 14:56:15):

- 8 beantwortbare Fragen zu Termin/Frist, Mehrheiten, Teilerbeitrag, Kostenschätzung, NRP-Honorar, Etappierung, Retention und HV-Traktanden.
- 3 negative Fragen: Versandnachweis, aktuelle Jahresrechnung/Budget/Teilerbasis, Grundbuchvollzug Parzelle 1784.

## 5. Schritt 3 — Synthese

Vier belegte Wissensseiten, alle **`needs_review` / unbestätigt**, jeweils mit Fassungs-IDs als Belegkanten:

| Titel | Knowledge-ID | Belege |
| --- | --- | --- |
| HV-Regeln der Flurgenossenschaft | `knw-0da1a481abaf438d9d85eba1804c80e1` | DRV-045 |
| HV 2026: Termin, Traktanden, Einladung | `knw-9f643c016cdf449bb163bc6b5e2accb1` | DRV-060, DRV-062, DRV-045 |
| Sanierung: Kosten, Honorar, Etappierung, Retention | `knw-5ac4568414b64bde86550dc7a93191fa` | DRV-008, NRP, DRV-059, DRV-007 |
| Finanzstand 2024/2025 | `knw-3b3217bdd42f4f1896e0c54f4445ed88` | DRV-018, DRV-060 |

Jede Seite trägt im Text «Status: Synthese, unbestätigt»; es wurden **0 Reviews/Bestätigungen** angelegt. Nach der Synthese: 10 Wissensabschnitte, 106 Belegabschnitte, `verify ok`. Details: `reports/SCHRITT-3-SYNTHESE.md`.

## 6. Schritt 4 — Test

**8/8 beantwortbare Fragen bestanden**, **3/3 negative Fragen korrekt als nicht belegbar beantwortet**, **0 Review-Fälle**.

- F1: 29.10.2026, 19:00, Schaugenhof; Einladungsfrist drei Wochen, rechnerisch 08.10.2026 (DRV-060 S. 7; DRV-062 S. 1; DRV-045 Art. 10 S. 3).
- F2: absolute Mehrheit; finanzielle Beschlüsse nach Teilern; Änderungen an Benützungsrechten/Parzelle nur mit Zustimmung jeder Parzelle (DRV-045 Art. 9 S. 3).
- F3: CHF 600.00 für 2025/26; 44 dafür, 8 dagegen, 6 Enthaltungen (DRV-060 S. 6).
- F4: 892'000 CHF brutto; FLG 715'800 CHF brutto; 666'800 CHF netto; +/- 20 %, exkl. MwSt. (DRV-008 S. 1–2).
- F5: 45'000 CHF inkl. MwSt.; exkl. Perimeteraufteilung, Einsprache, Zusatzausschreibung, Oberbauleitung (NRP S. 1/4).
- F6: vier Etappen; rund 700'000 CHF FLG-Anteil; erste Etappe akut (DRV-059 S. 1).
- F7: 28.8 m3 berechnet; 30 m3 vorgesehen; 1-/5-jähriges Ereignis mit AFU klären (DRV-007 S. 1; DRV-059 S. 2).
- F8: Beschlussvorschläge 6.2 NRP-Honorarkredit, 6.3 Querleitung/getrennter Kredit, 8.2 getrennte Führung von Unterhalts-/Verbrauchsteil und Erneuerungsfonds, 8.3 Finanzierung nach Statuten, 8.4 Vorstandsauftrag (DRV-062 S. 1–2).
- Negativ: F9 kein Versandnachweis; F10 keine aktuellen Zahlen/Teilerbasis (nur die im Präsidentenbericht DRV-011 genannte Basis 14 Eigentümer/78 Teiler, nicht als heutiger Stand); F11 kein Grundbuchauszug/kein heutiger Vollzug.

**Befund:** Die OCR der Statuten zieht Wörter zusammen (`istdieabsoluteMehrheit`). Die natürliche Suche „absolute Mehrheit“ findet daher keinen Belegtreffer; der exakte OCR-Token und die Wissensseite belegen die Stelle. Zusätzlich zitiert der Suchtreffer nur den ersten Suchbegriff, nicht die vollständige Antwortphrase; die vollständige Phrase wurde direkt im Text geprüft. Details: `reports/SCHRITT-4-TEST.md`, `reports/test-results.json`.

## 7. Themenlandkarte als Wissensbasis-Client

Die bestehende Themenlandkarte wurde fuer den Piloten als Client angebunden. Der Verbindungsdienst startet mit `-WissensbasisConfig` im Store-Modus, ruft ausschliesslich die lokale `wb`-Zugriffsschicht auf und baut keinen Verzeichnisindex. Die Oberflaeche zeigt **Echte Daten** mit Store-Pfad und Index-Build und oeffnet beim Einstieg die Seite **Sanierung: Kosten, Honorar, Etappierung, Retention**. Der Wissensarbeitsplatz ist dreispaltig: links Themenbaum und vier kanonische Wissensseiten, Mitte die lesbare Seite mit `needs_review`, rechts die prominente Fragefunktion oben, darunter Quellenstellen und verwandte Seiten. **Themenkarte**, **Quellen & Betrieb** und **Architektur** sind eigene Tabs; die technische Quellen-/Auswertungsansicht ist schreibgeschuetzt, Originale werden ueber `wb original` geladen. Die Architekturansicht zeigt eine Übersicht der vier Schichten mit Datenflüssen, darunter Details, Statuswerte und Komponenten, ohne Zugangsdaten und ohne interne Pfade vor der Verbindung. Der Fragebereich zeigt die neueste Frage zuerst, hält frühere Paare, markiert Belegverweise und zeigt Rohtexte aufklappbar. Verknuepfungen stammen aus vorhandenen Belegen oder sind als automatisch vorgeschlagen markiert. Es wurde keine zweite Oberflaeche und keine zweite Datenhaltung angelegt.

Start:

```powershell
& .\themenlandkarte\preview.ps1
& .\themenlandkarte\connector.ps1 -Origin http://127.0.0.1:43128 -WissensbasisConfig C:\AI-OS-Pilot\flurgenossenschaft\config.json
```

Die App ruft die Routen `/kb/search`, `/kb/evidence`, `/kb/ask` und `/kb/original` auf; der Dienst ruft `wb search`, `wb evidence` und `wb original` auf. Kein SQLite-Zugriff aus der Oberflaeche. Die Suche ist auch als `?q=<begriff>`, ein Beleg als `?evidence=<version-id>&page=<seite>` und die Ansichten als `?view=kbmap`/`?view=operations` aufrufbar.

Die Fragefunktion nutzt die Volltextsuche und optional eine konfigurierte KI-Anbindung (`-AiConfig`, OpenAI-kompatibel oder Ollama). Ein echter DeepSeek-Test mit `DEEPSEEK_API_KEY` aus der lokalen Benutzerumgebung ist dokumentiert; Schlüsselwerte werden nicht ausgegeben und nicht im Repository gespeichert. Im Retrieval-Modus antwortet sie mit einem ausdruecklich als unbestätigt gekennzeichneten Auszug aus der passenden Wissensseite und nennt Quellenbelege; Folgefragen beruecksichtigen den Verlauf. Fuenf fachliche Fragen sind in `reports\ask-five-ai.json` dokumentiert. Fuer den `leader`-Modus ist eine zweistufige **fachliche Bestätigung** bzw. **Überarbeitung nötig** mit fünf Prüfschritten, Prüfperson, Notiz und Basis-Hash über `wb review confirm/reject` eingebaut; die linke Leiste zeigt Status, Datum und Prüfperson. Rechts stehen die Quellen zur Wissensseite getrennt vom Chat mit Titel, Datum, Verwendet-für, Fundstellen und Details; Seitenzitate sind anklickbar, die globale Ansicht ist nach Wissensseiten geordnet, Chatantworten nennen ihre eigenen Belege. Der Live-Store bleibt bei 0 Reviews, getestet wurde auf einer Kopie. **Nicht implementiert** bleiben: semantische Suche, Vier-Augen-Erzwingung und Sammelbestätigung. Details und Ablauf: `themenlandkarte/README.md`; Prüfprotokoll: `C:\AI-OS-Pilot\flurgenossenschaft\reports\SCHRITT-CLIENT.md` und `KI-TEST-DEEPSEEK.md`.

## 8. Grenzen und offene Punkte

- Alle Wissensseiten sind **unbestätigt**; der Test bestätigt Nachvollziehbarkeit, nicht fachliche Richtigkeit.
- Die 12 Quellen sind eine Auswahl, nicht der gesamte Case. Der Test belegt Nicht-Antwortbarkeit nur für diesen Bestand.
- OCR/PDF-Grenzen: Layout, Tabellen, Pläne, Bilder und Unterschriften werden nicht rekonstruiert; Statuten-OCR ist fehleranfällig.
- Kein Versandnachweis, keine aktuelle Jahresrechnung/Budget 2026/27, kein Grundbuchauszug und keine heutige Mitglieder-/Teilerbasis im Bestand.
- Die Themenlandkarte wurde als Client erweitert; Store, RAW und Case-Dateien blieben unverändert; kein Produktions-Store `C:\AI-OS-Wissensbasis` angelegt.

## 9. Artefakte

- RAW: `C:\AI-OS-Pilot\flurgenossenschaft\RAW`
- Store: `C:\AI-OS-Wissensbasis-Flurgenossenschaft-Pilot`
- Testplan: `C:\AI-OS-Pilot\flurgenossenschaft\TESTFRAGEN.md`
- Synthese: `C:\AI-OS-Pilot\flurgenossenschaft\synthesis\`
- Schrittdokumente: `reports\SCHRITT-1-RAW.md`, `SCHRITT-2-INGEST.md`, `SCHRITT-3-SYNTHESE.md`, `SCHRITT-4-TEST.md`
- Maschinenlesbare Ergebnisse: `reports\import.json`, `reports\ocr-*.json`, `reports\test-results.json`, `reports\verify-*.json`
- Client und Fragefunktion: `reports\SCHRITT-CLIENT.md`, `reports\KI-TEST-DEEPSEEK.md`, `reports\ask-five-ai.json`, `reports\ask-five-ai-full.json`, `reports\kb-workbench-final.png`, `reports\kb-question-history.png`, `reports\kb-architecture.png`
