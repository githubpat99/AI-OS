# Zentrale Wissensbasis — Architektur und Pilot

Stand: 2026-11-05 · Status: **Entwurf zur Prüfung; lesender Pilotkern umgesetzt** · Keine Daten verschoben, keine Repositories zusammengelegt, keine Originale verändert.
## Zweck

Dieses Dokument definiert eine zentrale, von den Oberflächen unabhängige Wissensbasis für die drei Organisationen (Consulting, Engineering, Private) und die drei Ziele:

- **Sammeln:** Quellen aller Art werden erfasst, ohne Originale zu verändern.
- **Finden:** ein wiederherstellbarer Suchindex liefert belegte Treffer.
- **Vertrauen:** Herkunft, Version, Rechte und manuelle Bestätigung sind für jeden Inhalt nachvollziehbar.

Die Wissensbasis ist **kein** weiteres Dokumentenverzeichnis und **keine** Oberfläche. Sie ist eine lokale Kernschicht mit stabilem Datenvertrag; die Themenlandkarte und künftige Clients sind nur Konsumenten.

## Dokumentenkarte

| Dokument | Inhalt |
| --- | --- |
| [01_BESTANDSAUFNAHME.md](01_BESTANDSAUFNAHME.md) | Geprüfter Ist-Zustand der Repositories, vorhandenen Importe, Volumen, Lücken und Risiken |
| [02_ARCHITEKTUR.md](02_ARCHITEKTUR.md) | Schichten, Komponenten, Architekturdiagramm, Technologieentscheidungen, Grenzen |
| [03_DATENMODELL.md](03_DATENMODELL.md) | Entitäten, Identität/Versionen, Herkunft, Rechte inkl. abgeleitetem Wissen, Bestätigungen |
| [04_ABLAGE_UND_ABLAEUFE.md](04_ABLAGE_UND_ABLAEUFE.md) | Ablagestruktur, Import-/Aktualisierungs-/Schreibabläufe, Index-Wiederherstellung, Betrieb |
| [05_PILOTIMPORT.md](05_PILOTIMPORT.md) | Begrenzter Pilot, Testfälle und messbare Abnahmekriterien |
| [06_SICHERUNG.md](06_SICHERUNG.md) | Konkreter Sicherungsvorschlag für ungesicherte Quellen und unversionierte Inhalte |
| [07_PILOTKERN.md](07_PILOTKERN.md) | Umgesetzter lesender Pilotkern, Befehle, Testnachweis und Grenzen |
| [08_PILOTABNAHME.md](08_PILOTABNAHME.md) | Durchführung und Ergebnis von Profil A mit bestandenen, fehlgeschlagenen und nicht geprüften Kriterien |
| [09_BELEGUEBERHOLUNG.md](09_BELEGUEBERHOLUNG.md) | Nachweise zu A17/A20 (offen), Belegüberholung, PDF-Text und OCR mit Seitenbezug |
| [10_FLURGENOSSENSCHAFT_PILOT.md](10_FLURGENOSSENSCHAFT_PILOT.md) | RAW → Ingestion → Synthese → Test am Flurgenossenschaft-Bestand |

## Kurzfassung der Architektur

1. **Drei Ebenen:** Quellen (registrierte Herkunft) → Belege (unveränderliche Fassungen mit Hash) → Wissen (abgeleitete, bestätigbare Inhalte mit Belegkanten).
2. **Ein Kern, viele Oberflächen:** Der Kern ist ein lokales Python-Werkzeug (Standardbibliothek, SQLite). Oberflächen lesen und schreiben ausschließlich über den versionierten Vertrag `wb/v1` (CLI-JSON, später lokale HTTP-API). Keine Oberfläche liest die Datenbank direkt.
3. **System of Record:** `knowledge.sqlite3` (WAL) für Metadaten, Versionen, Rechte und Bestätigungen; unveränderliche, inhaltsadressierte Blobs auf der Platte.
4. **Suchindex ist abgeleitet:** Ein separater FTS5-Index wird aus dem Register und den Text-Blobs neu gebaut. Er darf jederzeit gelöscht und ohne Datenverlust rekonstruiert werden.
5. **Herkunft und Version sind Pflicht:** Jede Fassung hat Quellenbindung, SHA-256, Erfassungszeit, Extraktorversion und optional Belegstellen. Inhalte werden nie überschrieben, nur ergänzt oder abgelöst.
6. **Rechte vererben sich auf abgeleitetes Wissen:** Ein abgeleiteter Inhalt ist höchstens so offen wie der strengste seiner Belege. Raum- und Vertraulichkeitsgrenzen werden bei Änderungen neu bewertet.
7. **Manuelle Bestätigung ist ein eigener, prüfbarer Vorgang:** Bestätigungen sind an konkrete Fassungen gebunden und werden bei neuen Belegen als überholt markiert, nie stillschweigend übertragen.
8. **Trennung von Inhalt, Code, Werkzeug und Temporaerdateien:** Wissen liegt außerhalb aller Git-Repositories; Code und Werkzeuge liegen unter `shared/tools/`; Zwischendateien nur im Store unter `tmp/` mit garantierter Bereinigung.
9. **Keine Schreibkanäle auf Originale im Pilot:** Quellen werden standardmäßig nur gelesen. Ein späterer, ausdrücklich freizugebender Schreibkanal ist spezifiziert, aber im Pilot deaktiviert.
10. **Lokal zuerst:** Ein Store pro Rechner, keine Cloud-Datenbank, keine externen Dienste, keine Telemetrie. Übertragung zwischen Rechnern nur als bewusst erzeugtes Exportpaket.

## Umsetzungsstand

Der **lesende Pilotkern ist implementiert und getestet**: `shared/tools/wissensbasis/` (Python-Standardbibliothek), **16 Tests bestanden**. Enthalten sind Import, Herkunft/Fassungen, Originalabruf, lexikalische Volltextsuche, Index-Rebuild, konsistentes Backup/Restore, schreibgeschützte Pakete, Notizen/Bestätigungen, Zugriffsprüfungen sowie PDF-Text und OCR über eine optionale, isolierte Extraktor-Laufzeit. **Profil A wurde am 2026-11-05 mit echten Quellen ausgeführt**: 49 Elemente, 51 begründet übersprungen, alle geprüften Abnahmekriterien bestanden; **A17 und A20 sowie der Schutz vor Festplattenausfall sind ausdrücklich nicht geprüft**. PDF-Text (Text-PDF) und OCR (Scan) wurden je an einem PDF nachgewiesen; **Profil B mit allen 50 PDFs ist nicht durchgeführt**. Details: [08_PILOTABNAHME.md](08_PILOTABNAHME.md) und [09_BELEGUEBERHOLUNG.md](09_BELEGUEBERHOLUNG.md).

**Ausdrücklich noch offen:** semantische Suche (Embeddings/Vektoren), automatische Zusammenfassungen, Wissensverdichtung zu Claims/Entscheidungen, Profil B mit allen 50 PDFs, OCR-Qualität für weitere Scanarten, PST/MSG, Schreibkanal in Quellen, Oberflächen.

Ein separater Anwendungsnachweis mit 12 Originalquellen, vier unbestätigten Wissensseiten und 11 Testfragen ist in [10_FLURGENOSSENSCHAFT_PILOT.md](10_FLURGENOSSENSCHAFT_PILOT.md) dokumentiert.

## Kernentscheidungen

| ID | Entscheidung | Begründung | Folge |
| --- | --- | --- | --- |
| K1 | Genau ein führender Store außerhalb aller Repositories, Standard `C:\AI-OS-Wissensbasis`; Zweitrechner erhalten nur eingefrorene Read-only-Pakete | Kein Wissen im App-Code; keine Git-Größen- oder Rechteprobleme; kein Live-Sync einer aktiven SQLite-Datenbank | `wb init` prüft Repo/Temp/OneDrive; Rolle `leader`/`mirror` im Manifest; `mirror` verweigert alle Schreibbefehle |
| K2 | Python-Kern (3.10+), nur Standardbibliothek, SQLite/FTS5. PDF- und OCR-Extraktion laufen optional über eine isolierte, versionierte Extraktor-Laufzeit außerhalb von Store und Repository; Office wird über XML im Kern gelesen (`partial`). | Der Kern bleibt ohne Fremdpakete installierbar; auf dem Rechner vorhanden: Python 3.14, SQLite 3.50.4, FTS5/JSON1 (geprüft). Für PDF/OCR sind nachweislich Fremdpakete nötig. | Werkzeug- und Extraktorversionen stehen im Manifest; ohne Extraktor-Laufzeit bleibt PDF `unsupported` mit Grund. |
| K3 | Kanonische Metadaten in einer SQLite-Datenbank, Inhalte als inhaltsadressierte Blobs | Bewährt im vorhandenen Mail-Import; Dedupe, Integrität und schnelle Abfragen | WAL, tägliche konsistente Snapshots, `verify`, `restore` |
| K4 | Suchindex als separate, jederzeit neu baubare Datenbank | „Wiederherstellbarer Suchindex“ ist Kernanforderung | Index löschen und neu bauen ist ein normaler Betriebsvorgang |
| K5 | Im lesenden Pilotkern werden **keine Originalbytes kopiert**. Gespeichert werden Fassungshash, Metadaten und extrahierter Text; Originalabruf liest aus der Quelle und prüft den Hash. | Keine Verdopplung privater Originale; Originale bleiben unersetzlich in ihrer Quelle | `version.original_stored=0`; Originalabruf scheitert bei fehlender/veränderter Quelle; dauerhafte Original-Snapshots bleiben O2 |
| K6 | Herkunft/Version statt „letzter Stand“ | Vertrauen braucht nachvollziehbare Fassungen | Jede Änderung erzeugt eine neue Fassung; alte Fassungen bleiben abrufbar |
| K7 | Rechte werden aus Belegen abgeleitet (Schnittmenge), nicht behauptet | Verhindert, dass Zusammenfassungen Rechte ausweiten | Gemischte Herkunft (Geschäft + Privat) wird `mixed` und nur mit ausdrücklicher Freigabe nutzbar |
| K8 | Bestätigung ist ein Ereignis mit Prüfer, Zeitpunkt und Belegbasis | „Manuell bestätigt“ muss überprüfbar sein | Neue Belegfassung markiert Bestätigung als überholt; Inhalt bleibt unverändert |
| K9 | Oberflächenunabhängigkeit über JSON-Vertrag, nicht über gemeinsame Datenbank | Clients können ersetzt werden, ohne Daten zu beschädigen | `schema_version` + `wb/v1`; Clients ohne DB-Direktzugriff |
| K10 | Keine automatische KI-Ableitung im Pilot | Sammeln/Finden/Vertrauen zuerst; KI-Ausgaben wären ungeprüfte Inhalte | Ableitung nur mit ausdrücklichem Auftrag und Belegprüfung; kein Schreibzugriff durch Modelle |
| K11 | Import ist idempotent und wiederaufnehmbar | Große Bestände, Abbrüche, lange Läufe | Inhalt-Hash als Identität; Wiederholung erzeugt keine Duplikate |
| K12 | Keine Schreib-Back-Funktion im Pilot | „Originale nicht überschreiben“ | W2 bleibt spezifiziert, aber deaktiviert und nur je Quelle freigebbar |
| K13 | Zugriff = konfiguriertes Recht **und** tatsächlicher Dateizugriff **und** Klassifikation. `mixed` ist nur eine Klassifikation. | Ein Raumetikett allein sagt nichts über tatsächliche Dateirechte | `os.access`-Beobachtung je Bindung/Datei; `acl check/recheck`; andere Principals ohne OS-Nachweis werden abgelehnt |
| K14 | Datenklassen werden getrennt: unersetzliche Originale (extern), Ledger, extrahierter Text, reproduzierbarer Index, Exporte, Rechnerkonfiguration. | Nur so ist klar, was gesichert und was neu gebaut wird | `MANIFEST.data_classes`; `wb backup` sichert Ledger+Text; Index wird nicht gesichert |

## Was ausdrücklich nicht geändert wird

- Keine Datei wird verschoben, umbenannt oder gelöscht.
- Keine Repositories werden zusammengelegt oder neu initialisiert.
- Keine Originale werden überschrieben; der Pilot liest nur.
- Bestehende Register (SOURCE_REGISTER, Dokumenten-/Mailregister), `04_KNOWLEDGE` und die Themenlandkarte bleiben führend bzw. unverändert.
- Die uncommittete Quellenverwaltung der Themenlandkarte bleibt liegen; sie ist nicht Teil dieser Architektur und wird vorerst nicht weiterentwickelt.
- Semantische Suche und Wissensverdichtung werden nicht gebaut; sie bleiben ausdrücklich offene, spätere Funktionen.
- Dieses Verzeichnis enthält ausschließlich Entwurfsdokumente, keine Wissensinhalte.

## Offene Entscheidungen vor der Umsetzung

| ID | Frage | Empfohlene Vorgabe |
| --- | --- | --- |
| O1 | Endgültiger Store-Pfad (Standard `C:\AI-OS-Wissensbasis`, alternativ anderes Laufwerk) | Eigener Ordner, nicht in OneDrive, nicht im AI-OS-Verzeichnis; mindestens 20 GB frei |
| O2 | Sollen Originalbytes dauerhaft zentral gespeichert werden? | Pilot: **nein** (Hash + Text + Originalabruf aus der Quelle). Für den Dauerbetrieb gesondert entscheiden. |
| O3 | Aufbewahrung gelöschter Quellen und alter Fassungen | Standard: nie automatisch löschen; `purge` nur ausdrücklich und protokolliert |
| O4 | Sind Wissensnotizen im Store kanonisch oder erst nach Export in ein Repository? | Kanonisch im Store, mit `published_ref` beim späteren Export; Repository-Dokumente bleiben als `curated` kanonisch |
| O5 | Wer ist Prüfer für Bestätigungen? | Lokales Benutzerkonto mit Rollen `owner`, `reviewer`, `reader`; im Pilot nur der Nutzer |
| O6 | Verschlüsselung ruhender Daten | Pilot: NTFS-ACL + Benutzerprofil; Verschlüsselung als spätere Option prüfen (kein selbstgebautes Krypto) |
| O7 | Mehrere Rechner | Ein führender Store; Zweitrechner nur per Read-only-Paket; keine SQLite-Freigabe über Sync-Ordner |
| O8 | Umfang der ersten Erweiterung nach dem Pilot | Erst Mail-Adapter (bestehender Mail-Import), dann Oberflächenanbindung |
| O9 | PDF-/Office-Extraktion: isolierte Extraktor-Laufzeit für Profil B installieren oder Pilot auf textbasierte Formate (Profil A) begrenzen? | Profil A bleibt die Abnahmebasis. Die Laufzeit ist installiert; PDF-Text und OCR sind an zwei PDFs geprüft. Profil B (alle 50 PDFs) ist ein eigener, noch nicht durchgeführter Lauf. |
| O10 | Sicherungsziel und Offsite-Variante | Externes, BitLocker-verschlüsseltes USB-Laufwerk (≥ 128 GB); interim `G:` für einen ersten Satz; Offsite nur verschlüsselt |

## Freigabe und nächster Schritt

1. Diese Unterlagen prüfen; insbesondere O1–O5, O9 und O10 entscheiden.
2. Pilotumfang und Abnahmekriterien in [05_PILOTIMPORT.md](05_PILOTIMPORT.md) bestätigen. Profil A (41 reale Dateien + 8 Fixtures) ist die Abnahmebasis; Profil B (50 PDFs) ist optional und noch nicht durchgeführt. Die zusätzlichen Nachweise zu PDF/OCR und Belegüberholung stehen in [09_BELEGUEBERHOLUNG.md](09_BELEGUEBERHOLUNG.md); A17 und A20 bleiben offen.
3. Sicherungsziel gemäß [06_SICHERUNG.md](06_SICHERUNG.md) festlegen, bevor echte Quellen importiert werden.
4. Den Pilotkern gemäß [07_PILOTKERN.md](07_PILOTKERN.md) mit echten Quellen ausführen.
5. Nach bestandenem Pilot über Fortsetzung, Store-Pfad und Oberflächenanbindung entscheiden.
