# 08 — Pilotabnahme Profil A

Stand: 2026-11-05 · Lesender Pilotkern · **Profil A ausgeführt** · Keine Originale verändert.

## 1. Durchführung

| Punkt | Wert |
| --- | --- |
| Store | `C:\AI-OS-Wissensbasis-Pilot` (Rolle `leader`) |
| Lokale Konfiguration | `C:\AI-OS-Pilot\config.json` (bewusst vom Standardpfad getrennt, damit der Pilot keinen Dauerbetriebs-Store vorwegnimmt) |
| Pilotarbeitsordner | `C:\AI-OS-Pilot` (Fixtures, Notizen, Reports, Backup, Restore-Test, Paket, Spiegel) |
| Formate (Allowlist) | `md, txt, csv, json, html, docx, xlsx, pptx` – **kein PDF** |
| Vorprüfung der Ziele | `C:\AI-OS-Wissensbasis-Pilot` und `C:\AI-OS-Pilot` waren nicht vorhanden; es wurde nichts überschrieben |
| Reale Quellen | 3 Ordner (ZP, TAXA, Private FG), 92 Dateien, davon 41 im Profil A, 50 PDFs, 1 `.gitkeep` |
| Fixtures | 8 synthetische Dateien (inkl. Duplikat, ungültiges UTF-8, leere Datei) |
| Fehlende Quelle | `src-pilot-missing` (`C:\AI-OS-Pilot\missing`, absichtlich nicht vorhanden) |

Gescannt: **100 Dateien** → **49 Elemente erfasst**, **51 übersprungen** (50 PDFs außerhalb Profil A, 1 `.gitkeep`). Keine unbekannte Auslassung.

## 2. Ergebnis der Abnahmekriterien

| ID | Kriterium | Status | Nachweis |
| --- | --- | --- | --- |
| A1 | Vollständigkeit | **bestanden** | 100 gescannt = 49 erfasst + 51 begründet übersprungen; 49 Elemente im Store |
| A2 | Originale unverändert | **bestanden** | 92 reale Dateien vor/nach: 0 fehlend, 0 hinzugefügt, 0 geändert (SHA-256); auch nach realem Originalabruf (Business und Privat) erneut 0 Abweichungen |
| A3 | Idempotenz | **bestanden** | zweiter Import: 0 neue Elemente, 0 neue Fassungen, 49 unverändert |
| A4 | Extraktionswahrheit | **bestanden** | 38 `full`, 10 `partial` (DOCX/XLSX/PPTX mit Grund), 2 `failed` (ungültiges UTF-8, leere Datei); 50 PDFs in Profil A übersprungen. **PDF/OCR nachträglich separat geprüft (09), nicht Teil von A4** |
| A5 | Herkunft vollständig | **bestanden** | 50 Fassungen, je genau eine aktuelle Extraktion; `original_stored=0` für alle; 0 Quell-Hash-Abweichungen; 5 Bindungen |
| A6 | Belegstellen | **bestanden** | 122 Suchtreffer, 122 Zeichenstellen gegen den gespeicherten Text verifiziert; 0 Abweichungen nach der Korrektur (siehe Abschnitt 3) |
| A7 | Rechte | **bestanden** | Owner: `allowed=true`, Basis `os_access`; `reader-business`: Quelle und gemischte Notiz verweigert; Suche fremd: 0 Treffer, 7 gefiltert; `acl recheck`: 1 erwartete Abweichung (fehlende Quelle). **Reale ACL-Verweigerung nicht geprüft** |
| A8 | Bestätigung | **bestanden** | `confirmed` und `rejected`; falscher Basis-Hash → Exit 6 `review_conflict`; Bestätigung nach Restore erhalten. **Überholung durch neue Belegfassung im Nachtrag [09_BELEGUEBERHOLUNG.md](09_BELEGUEBERHOLUNG.md) geprüft** |
| A9 | Versionierung | **bestanden** | Fixture-Änderung: genau 1 neue Fassung, 7 unverändert; `notiz.md` hat 2 Fassungen; weiterer Import 0 neu |
| A10 | Dedupe | **bestanden** | Zwei inhaltsgleiche Gruppen (`duplikat.md`/`notiz.md`, zwei `README.md`): je 2 Elemente, 2 Fassungen, **1 Text-Blob** |
| A11 | Fehlerzustände | **bestanden** | `ungueltig.md`: `failed`/„kein gültiges UTF-8“; `leer.md`: `failed`/„Datei ist leer“; keine stillen Erfolge |
| A12 | Suche belegt | **bestanden** | 10 Abfragen, Treffer 1–28 je Abfrage, insgesamt 122 Treffer; alle mit Quelle/Element/Fassung/Zeichenstelle; Kernsuche p95 **5,98 ms** (200 Läufe) |
| A13 | Index wiederherstellbar | **bestanden** | Index gelöscht → Suche Exit 2 `index_missing`; Rebuild 0,141 s, 1 075 Abschnitte; vor/nach identische 122 Treffer und Ränge |
| A14 | Sicherung/Wiederherstellung | **bestanden** | Backup + Restore in separates `C:\AI-OS-Pilot\restore-test`: 49 Elemente, 50 Fassungen, 3 Notizen, 2 Reviews, `verify ok`, Suche 8 Treffer |
| A15 | Trennung/Sauberkeit | **bestanden** | `git status` vor/nach identisch; `tmp` 0; keine Konfiguration im Store; Store nicht im Repository; Store final 6,17 MB |
| A16 | Quelle nicht erreichbar | **bestanden** | Missing-Quelle `unreachable`; Fixture-Bindung temporär ungültig → `unreachable`, letzter Erfolg bleibt erhalten; nach Rückkonfiguration `reachable` |
| A17 | Abbruch/Wiederaufnahme | **nicht geprüft** | Kein kontrollierter Prozessabbruch während des Laufs ausgeführt |
| A18 | Vertrag/Exit-Codes | **bestanden** | 6 = Review-Konflikt, 2 = fehlender Index, 3 = Spiegelstore-Schreibversuch, 4 = Original im Spiegel, 5 = Verify-Fehler (`blobs_intact=false`) |
| A19 | Leistung/Umfang | **bestanden** | Import 1,07 s; Verify 0,49 s; Store 6,17 MB; Index 2,37 MB; alle Schwellen eingehalten. CLI-Suche inkl. Prozessstart p95 433 ms (Beobachtung, nicht Kriterium) |
| A20 | Rückbaubarkeit | **nicht geprüft** | Pilot-Store bewusst aufbewahrt; keine Löschung/Neuanlage ausgeführt |
| A21 | Abgrenzung | **bestanden** | Keine semantische Suche, keine Embeddings, keine Wissensverdichtung; Hilfe weist beides als noch nicht implementiert aus |

**Fehlgeschlagene Kriterien: keine** (nach der Korrektur in Abschnitt 3). **Nicht geprüfte Kriterien: A17, A20.** Zusätzlich ausdrücklich nicht geprüft: Profil B mit allen 50 PDFs, Schutz vor Festplattenausfall und reale ACL-Verweigerung. PDF/OCR wurde nachträglich an zwei PDFs geprüft, Belegüberholung mit einem synthetischen Claim (siehe `09`).

## 3. Während des Laufs gefundener und behobener Fehler

Die erste Belegprüfung (A6) fand 25 von 122 Zeichenstellen um ein Zeichen verschoben. Ursache: Die Suchstelle wurde im `casefold()`-Text gesucht; `casefold` kann die Länge verändern (z. B. `ß` → `ss`), wodurch der Offset nicht mehr auf den Originaltext passt.

- Korrektur: Positionsbestimmung mit `re.search(..., re.IGNORECASE)` im Originaltext (`wb/indexer.py`).
- Regressionstest ergänzt (`test_snippet_offsets_use_original_text`).
- Nach der Korrektur: **122/122** Zeichenstellen verifiziert; Index-Rebuild-Vergleich weiterhin identisch.

## 4. Messwerte

| Messung | Wert |
| --- | --- |
| Import (49 Elemente, ohne PDF) | 1,065 s |
| Verify (`--access`) | 0,49 s |
| Index-Rebuild | 0,141 s, 1 075 Abschnitte, 2 486 272 Bytes |
| Suche Kern (200 Läufe, 10 Abfragen) | p50 3,96 ms, p95 5,98 ms |
| Suche CLI inkl. Prozessstart (30 Läufe) | p95 433 ms |
| Store gesamt | 6,17 MB in 59 Dateien (DB 0,35 MB, Index 2,37 MB) |
| Extraktionsstatus | 38 `full`, 10 `partial`, 2 `failed` |

Zusätzlicher Originalabruf mit echten Quellen: `ABP_2026_Dashboard_Auszug.md` (Business) und `berichte/DRV-036-bericht-prasident-2021.docx.txt` (Privat). Kopie, Quelle und gespeicherter Fassungshash stimmen jeweils überein; die 92 realen Quellen blieben danach unverändert.

## 5. Artefakte

| Pfad | Inhalt |
| --- | --- |
| `C:\AI-OS-Pilot\reports\pilot-analysis.json` | Maschinenlesbare Auswertung |
| `C:\AI-OS-Pilot\reports\import-1.json` … `import-4.json` | Importberichte |
| `C:\AI-OS-Pilot\reports\search-golden-2.json` / `-3.json` | Goldabfragen vor/nach Rebuild |
| `C:\AI-OS-Pilot\reports\access.json`, `acl-recheck.json` | Zugriffsprüfungen |
| `C:\AI-OS-Pilot\reports\verify-final.json`, `verify-broken.json` | Integritätsprüfungen |
| `C:\AI-OS-Pilot\reports\restore.json`, `restore-checks.json` | Wiederherstellung |
| `C:\AI-OS-Pilot\reports\mirror.json`, `package.json` | Read-only-Austausch |
| `C:\AI-OS-Pilot\reports\source-before.json` / `source-after.json` | 92 Quell-Hashes |
| `C:\AI-OS-Pilot\backup-profile-a\` | Konsistente Sicherung |
| `C:\AI-OS-Pilot\restore-test\` | Wiederhergestellter Teststore |
| `C:\AI-OS-Pilot\package-profile-a\`, `mirror-test\` | Read-only-Paket und Spiegelstore |

Die lokalen Reports enthalten Suchauszüge; sie sind **nicht** im Repository. Dieses Dokument enthält keine Dokumentinhalte.

## 6. Offene Punkte nach dem Pilot

1. **PDF/OCR:** Im Profil-A-Lauf nicht enthalten; nachträglich an zwei PDFs geprüft (Text und Scan, inklusive OCR-Limit und Seitenbezug). **Profil B mit allen 50 PDFs ist nicht durchgeführt.**
2. **Schutz vor Festplattenausfall** wurde nicht geprüft. Backup, Restore, Paket und Spiegel liegen auf demselben Laufwerk `C:`; das belegt Wiederherstellbarkeit, nicht Ausfallschutz.
3. **A17 (Abbruch/Wiederaufnahme)** und **A20 (Rückbaubarkeit durch Löschen)** wurden nicht ausgeführt und bleiben offen.
4. **Reale ACL-Verweigerung** erfordert einen zweiten Principal und ist im lesenden Pilotkern nicht enthalten. Die **Überholung von Bestätigungen** wurde nachträglich mit einem synthetischen Claim geprüft (siehe `09`).
5. **Semantische Suche und Wissensverdichtung** bleiben ausdrücklich spätere, offene Funktionen.

## 7. Integrität der Umgebung

- Themenlandkarte: 23 Dateien vor/nach identisch (SHA-256); keine Änderung in diesem Lauf.
- Originale: 92 Dateien vor/nach identisch; keine Datei verschoben, umbenannt oder gelöscht.
- Repositories: `git status` vor/nach identisch; der Pilot schrieb ausschließlich nach `C:\AI-OS-Wissensbasis-Pilot` und `C:\AI-OS-Pilot`.
- Der Dauerbetriebs-Store `C:\AI-OS-Wissensbasis` wurde **nicht** angelegt.

## 8. Nachtrag vom 2026-11-05

Nach der Profil-A-Abnahme wurden zwei offene Punkte in getrennten Testläufen bearbeitet:

- **Belegüberholung:** Eine neue Fassung einer Testquelle setzt abhängiges Wissen auf `confirmation_stale` und die zugehörige Bestätigung auf „überholt“; die alte Fassung bleibt samt Text abrufbar, eine unabhängige Notiz bleibt bestätigt. `verify` ist ok.
- **PDF-Text und OCR:** Ein Text-PDF (4 Seiten) und ein Scan (18 Seiten) wurden in einer isolierten Laufzeit verarbeitet. OCR ist ein eigener Schritt, Seitenverweise sind in Suchtreffern enthalten, unvollständige OCR-Läufe werden als `partial` mit ausstehenden Seiten ausgewiesen. Originale blieben unverändert; Backup/Restore erhielt Seiten und Suche.

**A17 und A20 bleiben ausdrücklich nicht geprüft.** Profil B mit allen 50 PDFs ist nicht durchgeführt. Details, exakte IDs, Grenzen und Artefakte: [09_BELEGUEBERHOLUNG.md](09_BELEGUEBERHOLUNG.md).
