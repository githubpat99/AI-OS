# 01 — Bestandsaufnahme

Stand: 2026-11-05 · Methode: ausschließlich lesende Prüfung im AI-OS-Workspace; keine Datei verschoben, kein Repository verändert, kein Import ausgeführt, keine Tests gestartet, keine Netzwerkzugriffe. Zahlen sind an diesem Rechner gemessen und keine dauerhafte Zusicherung. Der spätere Profil-A-Import und die PDF-Tests sind in [08_PILOTABNAHME.md](08_PILOTABNAHME.md) und [09_BELEGUEBERHOLUNG.md](09_BELEGUEBERHOLUNG.md) dokumentiert und ändern die hier gemessene Ausgangslage nicht.

## 1. Repository-Topologie

| Pfad | Git-Wurzel | Remote | Getrackte Dateien | Befund |
| --- | --- | --- | --- | --- |
| `C:\Users\patri\AI-OS` | eigener Parent | `githubpat99/AI-OS` | 33 | Enthält nur Basisdateien (`AGENTS.md`, `README.md`, `shared/`, `themenlandkarte/`, `index.html`). Die drei Organisationen sind per `.gitignore` ausgeschlossen. |
| `AI-Consulting-OS` | eigener Clone | `githubpat99/AI-Consulting-OS` | 744 | Vollständige Organisation mit Fachordnern, Engagement-Registern und Importwerkzeugen. |
| `AI-Private-OS` | eigener Clone | `githubpat99/ai-private-os` | 318 | Private Cases inklusive Originalen (117 EML, 50 PDF), die auf ausdrücklichen Nutzerauftrag im privaten Repository versioniert werden. |
| `AI-Engineering-OS` | **keine eigene Git-Wurzel** | — | **0** | Der Ordner ist vom Parent ignoriert (`.gitignore` Zeile 3) und selbst kein Repository. `AGENTS.md`, `CURRENT_STATE.md`, `INDEX.md`, `briefs/` und `Engineering.code-workspace` sind damit **nirgends versioniert**. Nur die drei Projektordner darunter sind eigene Repositories. |
| `AI-Engineering-OS/projects/pensionierungsplanung` | eigener Clone | `githubpat99/pensionierungsplanung` | (Projekt) | 2 lokale Änderungen; Branch `main`. |
| `AI-Engineering-OS/projects/vermoegensplanung` | eigener Clone | `githubpat99/vermoegensplanung` | (Projekt) | 1 lokale Änderung; Branch `main`. |
| `AI-Engineering-OS/projects/next-app` | eigener Clone | `mysilverline` (SSH) | (Projekt) | 11 lokale Änderungen; Branch `main`. Enthält Silverline, WordPress-Backend und htmltools. |

Es gibt sechs Git-Wurzeln. Der Parent trackt keine Organisationsdateien; die Engineering-Organisationsebene fällt zwischen die Repositories. Das ist für die Wissensbasis relevant, weil „vertrauen“ auch Versionierung der eigenen Organisationsunterlagen voraussetzt.

## 2. Volumen und Dateitypen

Gemessen ohne `.git`, `node_modules`, `.venv`, `__pycache__`, `dist`, `build`.

| Organisation | Dateien | Größe | Wichtigste Typen |
| --- | ---: | ---: | --- |
| AI-Consulting-OS | 12 600 | 2 278.6 MB | 6 210 `.eml` (835.2 MB), 5 644 `.bin` (481.4 MB), 163 `.md`, 33 `.pdf` (64.3 MB), 33 `.html`, 8 `.pptx` (18.5 MB) |
| AI-Engineering-OS | 1 878 | 189.4 MB | 312 `.js`, 290 `.png`, 147 `.map`, 142 `.json`, 133 `.meta`, 132 `.ts`, 119 `.sst` (89.0 MB Build-Artefakte), 62 `.md` |
| AI-Private-OS | 318 | 150.3 MB | 117 `.eml` (37.3 MB), 87 `.md`, 51 `.pdf` (106.8 MB), 22 `.txt`, 12 `.docx`, 5 `.xlsx` |

Wichtige Einordnung:

- Der Großteil des Consulting-Volumens liegt unter `AI-Consulting-OS/local-only/mail-archive/test/`: **6 210 EML (835 MB), 5 644 Anhänge als `.bin` (481 MB), `mail-index.sqlite3` mit 74.5 MB**. `local-only/` ist per `.gitignore` ausgenommen und wird nicht über Git übertragen.
- Die getrackten 744 Consulting-Dateien sind der eigentliche Repository-Inhalt; die große Masse ist lokaler Mailbestand.
- Die Engineering-Zahlen sind überwiegend Build-Ausgabe (`.next`-Artefakte), kein Wissen. Das bestätigt die geforderte Trennung von Code, Werkzeugen und temporären Dateien.
- Es gibt keinen zentralen Speicherort für Wissen über die drei Organisationen hinweg. `%LOCALAPPDATA%\AI-OS` enthält nur `Themenlandkarte` (aktuell 0 MB nach Testbereinigung).

## 3. Vorhandene Bausteine und ihre Belastbarkeit

### 3.1 Mail-Import und RAG-Basis (Consulting)

Pfad: `AI-Consulting-OS/09_SYSTEM/ingestion/mail_import/` (Werkzeug, README, Tests, optionaler Ollama-Adapter).

| Aspekt | Befund |
| --- | --- |
| Technik | Python 3.10+, nur Standardbibliothek, SQLite/FTS5; im Ist geprüft: FTS5 und JSON1 verfügbar. |
| Identität | SHA-256 über vollständige EML-Bytes; `mail-<sha256>`; gleiche Message-ID mit abweichenden Bytes bleibt absichtlich erhalten. |
| Ablage | `local-only/mail-archive/<scope>/`: `originals/` (PST-Kopie), `extracted/` (unveränderte EML), `attachments/` (Hash-Dateinamen), `structured/` (Frontmatter-Markdown aus SQLite), `mail-index.sqlite3`, `last-import.json`. |
| Index | Tabellen `mails`, `imports`, `occurrences`, FTS5 `chunks`; lexikalische Suche mit BM25, keine Embeddings. |
| Prozess | Stapel von 100, Wiederaufnahme, Duplikaterkennung, Fehlerisolierung, Fortschritt auf stderr, JSON auf stdout, `rebuild` aus SQLite. |
| Qualität | Schema/Regeln dokumentiert in `04_KNOWLEDGE/mail-archive/README.md`; Belegpflicht `{source_id, quote}` für Modellaussagen; keine automatische Freigabe. |
| Grenzen für eine zentrale Wissensbasis | (1) Gilt nur für Mail, Scope-lokal, eine DB pro Scope. (2) DB ist einzige Metadatenquelle; kein Ledger, kein Backup-/Restore-Verfahren. (3) FTS5 liegt in derselben DB und ist nicht als separater, neu baubarer Index modelliert. (4) Anhänge werden gespeichert, aber nicht inhaltlich extrahiert. (5) Markdown-`structured/` war im gemessenen Test-Scope nicht vorhanden (nur `attachments/`, `extracted/`, `originals/`, DB) — die Rebuild-Stufe war dort nicht ausgeführt. (6) Keine Rechte- oder Bestätigungslogik. |
| Wiederverwendung | Muster werden übernommen: Inhalts-Hash als Identität, unveränderte Originalbytes, Frontmatter, FTS5, Belegprüfung, atomare Schreibvorgänge, Batch-Transaktionen. Keine direkte Weiterverwendung als zentraler Kern. |

Die zugehörige Prüfung `test_mail_import.py` existiert; sie wurde in diesem Auftrag **nicht** ausgeführt.

### 3.2 Steuerquellen-Import (Consulting)

Pfad: `AI-Consulting-OS/09_SYSTEM/ingestion/steuerquellen_import.py`, Registry `sources.yaml` (8.2 KB, 287 Zeilen), Ziel `05_SOURCE_MATERIAL/Steuern`.

- Liest ausschließlich konfigurierte offizielle Quellen, lädt HTML/PDF, erkennt Änderungen per SHA-256, schreibt `.meta.yaml` je Dokument, bietet `--dry-run`.
- Die Registry beschreibt Quellen mit ID, Staatsebene, Gebiet, Behörde, Quellentyp, Rechtsgrundlage, URL, Zielverzeichnis, Priorität und Aktivstatus.
- `05_SOURCE_MATERIAL/Steuern/CH` enthält derzeit nur `.gitkeep` — es wurden also noch keine Steuerquellen importiert.
- Grenze: Der Import schreibt in das Repository und ist quellenspezifisch. Er ist ein **Beschaffungs**werkzeug, keine zentrale Wissensbasis. Die Registry-Idee (stabile Quellen-ID, Typ, Ziel, Aktivstatus) wird übernommen.

### 3.3 Manuelle Register (Consulting und Private)

| Datei | Form | Belastbarkeit |
| --- | --- | --- |
| `07_ENGAGEMENTS/active/ENG-2026-001-.../sources/SOURCE_REGISTER.md` | Tabelle `U-01…`, `S-01…` mit Aussage, Herkunft, Status, Einschränkung | Belegt Arbeitsstand und Prüfgrenzen; keine maschinenlesbare Identität. |
| `07_ENGAGEMENTS/active/ENG-2026-002-.../sources/SOURCE_REGISTER.md` | gleichartig | gleichartig |
| `AI-Private-OS/cases/flurgenossenschaft-gruenaustrasse/document-register.md` | `DRV-001…`, Kategorie, Erfassung, Sichtung, Drive-Quelle; 61 Quellen, 39 Originale/22 Text-Snapshots | Sehr gute fachliche Provenienz; Prüfsummen liegen laut Text in `document-register.json`. |
| `AI-Private-OS/cases/.../mail-register.md` | 115 Mails in 30 Verläufen, Suchgrenzen, Quellenabgleich per SHA-256 | Belegt Suche und Grenzen; keine zentrale Verknüpfung. |
| `AI-Consulting-OS/04_KNOWLEDGE/tax/90_register/quellenregister.md` u. a. | leere Tabellenvorlagen | Struktur ohne Inhalt. |

Die Register sind fachlich wertvoll und bleiben im Pilot führend. Die Wissensbasis muss bestehende Register-IDs (`SRC-…`, `DRV-…`, `U-…`) aufnehmen können, ohne sie zu ersetzen.

### 3.4 Wissensstruktur `04_KNOWLEDGE` (Consulting)

- **459 Dateien, 465 Ordner**, davon **423 `.gitkeep`** und **36 `.md`** (überwiegend READMEs und Vorlagen).
- Die `tax`-Ablage ist ein tiefes, kantonales Raster (Prozessbereiche × Kantone × CH/gemeinsam) mit fast ausschließlich leeren Platzhaltern.
- Die Register `wissensregister.md`, `wissensluecken.md`, `quellenregister.md` sind leere Vorlagen.

Das ist eine **Struktur ohne Bücher**: Sie darf nicht als bestehende Wissensbasis missverstanden werden. Der Pilot füllt sie nicht und migriert sie nicht.

### 3.5 Themenlandkarte (Parent-Repository)

Pfad: `themenlandkarte/` (statische App, PowerShell-Connector, Python-Extraktor, Tests).

- Funktionsstand aus dem Repository: Dokumentleser, Volltextsuche über gelesene lokale Texte, Themenzuordnung, Fortschritt, automatische Aktualisierung nach Speichern, Quellen-/Dokumentzustände, öffentlicher Beispielbuild.
- Lokaler Zustand unter `%LOCALAPPDATA%\AI-OS\Themenlandkarte\` (Reader-Historie, Konfiguration, Laufzeit). Kein zentraler Index.
- **Uncommittet und eingefroren:** `connector.ps1`, `document-reader.html`, `document-state.ps1`, `index.html`, `map.template.html`, `public/index.html`, `publish.ps1`, `test.ps1` (geändert) sowie `source-state.ps1` (neu). Diese Arbeit implementiert eine Quellenverwaltung, ist aber nicht committet und wird gemäß Auftrag nicht weiterentwickelt. Sie ist **keine** Grundlage der hier beschriebenen Architektur; einzelne Begriffe (stabile Quellen-ID, Erreichbarkeit, letzter Erfolg, ausstehende Verarbeitung, unbekannter Zustand) fließen als Anforderungen ein.

### 3.6 Konfiguration, Zustand und Werkzeuge

| Ort | Inhalt | Bewertung |
| --- | --- | --- |
| `%LOCALAPPDATA%\AI-OS\Themenlandkarte` | Reader-Historie, Quellenkonfiguration, Python-Laufzeit | Rechnerbezogen, außerhalb der Repositories; gutes Muster |
| `AI-Consulting-OS/local-only/` | Mailarchiv, Indizes | Gitignoriert, nicht gesichert, nicht übertragen |
| `shared/` | `PERFORMANCE.md`, `ROUTING.md`, Vorlagen | Gemeinsame, versionierte Regelbasis; 5 getrackte Dateien. Die neuen Entwurfsdokumente unter `shared/wissensbasis/` sind noch nicht committet. |
| Systemwerkzeuge | Python 3.14.0, SQLite 3.50.4 (FTS5 und JSON1 geprüft), Git 2.53.0, Node 24.11.1 | Ausreichend für den Kern; keine Zusatzpakete nötig |
| Freier Speicher | C: 52.9 GB | Ausreichend für Store und Pilot |

## 4. Lücken gegenüber den Zielen

| ID | Lücke | Folge | Antwort der Architektur |
| --- | --- | --- | --- |
| G1 | Keine zentrale Identität für Quellen über Organisationen hinweg | Gleiche Quelle mehrfach, keine belastbare Herkunftskette | `source` + `source_binding` mit stabilen IDs, Herkunft und Rechten |
| G2 | Keine Fassungen: „letzter Stand“ dominiert | Änderungen nicht nachvollziehbar, Belege nicht reproduzierbar | Unveränderliche Versionen mit Hash, Zeit, Extraktor |
| G3 | Keine gemeinsame Rechte- und Raumlogik | Vermischung Geschäft/Privat möglich; abgeleitete Inhalte ohne Schutz | Raum- und Vertraulichkeitsmodell mit Vererbung auf Ableitungen |
| G4 | Kein Bestätigungsmodell | „geprüft“ ist nicht belegbar | Review-Ereignisse mit Prüfer und Belegbasis |
| G5 | Suchindex nicht als abgeleitete Schicht modelliert | Indexverlust wäre Datenverlust; keine Wiederherstellung | Separater, jederzeit neu baubarer FTS5-Index |
| G6 | Mail-Import ist der einzige Index, aber nicht sicherbar | 74.5-MB-DB ohne Backup-/Restore-Verfahren | Ledger + tägliche Snapshots + `verify`/`restore` |
| G7 | Engineering-Organisationsunterlagen sind nicht versioniert | Verlust-/Widerspruchsrisiko bei Status und Briefs | Offener Punkt, außerhalb des Piloten; nicht durch die Wissensbasis lösbar |
| G8 | Große Bestände liegen gitignoriert in `local-only` | Kein Backup, keine Übertragung, kein Vertrauen in Vollständigkeit | Wissensbasis speichert Belege unabhängig; Aufbewahrung je Quelle |
| G9 | Register sind manuell und formatverschieden | Keine maschinenlesbare Verknüpfung | `register_id`-Mapping, Register bleiben führend |
| G10 | Anhänge und Binärformate sind nur abgelegt, nicht ausgewertet | Suche findet Anhanginhalte nicht | Expliziter Extraktionsstatus je Fassung; keine Scheinvollständigkeit |
| G11 | Es gibt keine Trennung „kanonisches Wissen“ vs. „Ableitung“ | Zwei Wahrheiten drohen | `canonical`-Kennzeichen, Repository-Dokumente `curated`, Store-Notizen kanonisch |
| G12 | Keine Tests/Betriebsverfahren für einen zentralen Bestand | Fehler wären erst im Alltag sichtbar | Pilot mit Abnahmekriterien, `verify`, Fehlerinjektion |

## 5. Risiken

| Risiko | Wirkung | Gegenmaßnahme |
| --- | --- | --- |
| Doppelte Wahrheit (Repository und Store) | Widersprüchliche Aussagen, Pflegeaufwand | Kanonisch-Regel (K/O4), Ableitungen mit `published_ref`, keine automatische Rückführung |
| Sensible Daten im Store | Größere Angriffs-/Kopierfläche | NTFS-ACL, Benutzerprofil, keine Cloud/kein Sync im Store, optional Verschlüsselung später |
| SQLite in Sync-Ordnern | Korruption/Deadlocks | Store ausdrücklich außerhalb OneDrive/Netzwerk; `wb init` prüft |
| Große Bestände (2.3 GB, 12 600 Dateien) | Lange Importe, Speicherdruck | Pilot begrenzt; Inkrementell, Dedupe, Fortschritt, Wiederaufnahme |
| Fehlende Extraktion (PDF/DOCX/EML-Anhänge) | Unvollständige Suche | Status `partial`/`failed` mit Grund, keine stillen Lücken; Pilot akzeptiert nur belegte Abdeckung |
| Gemischte Räume | Datenschutzverletzung | `mixed` + Schnittmengenrechte + Prüfpflicht |
| Bestehende Register weichen ab | Vertrauensverlust | Register-IDs importieren, Abweichungen als offene Punkte ausweisen |
| Unversionierte Engineering-Dokumente | Verlust | Separater Auftrag; nicht im Pilot lösen |
| Werkzeug-Update bricht Altbestand | Daten nicht mehr lesbar | `schema_version`, Migrationen, Export/Import, Tests |
| Nutzer erwartet „fertige Wissensbasis“ | Enttäuschung | Klare Pilotabgrenzung, Abnahmekriterien, keine Oberflächenversprechen |

## 6. Wiederverwendung und Abgrenzung

**Übernehmen:** Inhalts-Hash als Identität; unveränderte Originalbytes; Frontmatter/JSON-Metadaten; SQLite/FTS5; Belegzitate mit Prüfung; Batch-/Wiederaufnahme; atomare Schreibvorgänge; Scope-Trennung als Vorbild für Räume; Quellen-Registry-Felder; manuelle Register-IDs.

**Nicht übernehmen:** Mail-Import als zentralen Kern; eine DB pro Scope; Index in derselben DB; Modellableitung als Standard; Schreiben in Repository-Ordner durch den Kern; UI-zentrierte Zustandsführung; Dateisystem als einzige Metadatenquelle.

**Nicht Teil dieses Auftrags:** Migration der 12 600 Dateien, Zusammenführung der Repositories, Änderung der Themenlandkarte, Engineering-Versionierung, Verschlüsselung, Mehrbenutzerbetrieb, Cloud-Synchronisation.

## 7. Nachtrag: umgesetzter Pilotkern (2026-11-05)

- Der lesende Kern liegt unter `shared/tools/wissensbasis/` (Python-Standardbibliothek) und ist mit 16 Tests geprüft; Details in [07_PILOTKERN.md](07_PILOTKERN.md), [08_PILOTABNAHME.md](08_PILOTABNAHME.md) und [09_BELEGUEBERHOLUNG.md](09_BELEGUEBERHOLUNG.md).
- Es wurden **keine echten Quellen** importiert und **kein Store** angelegt.
- Git-Abgleich bei der Messung: alle sechs Repositories `ahead=0, behind=0` (gepusht); lokal uncommittet: Parent 11, pensionierungsplanung 2, vermoegensplanung 1, next-app 11 Dateien. Diese uncommitteten Änderungen sind nicht gesichert.
- Die Sicherungslücke für `local-only/mail-archive` und die Engineering-Organisationsebene bleibt bestehen; der Vorschlag steht in [06_SICHERUNG.md](06_SICHERUNG.md).
