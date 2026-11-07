# Aufnahme-Pipeline – Backend-Schnittstelle

Die Aufnahme ist in `poc.ps1` implementiert und über `pipeline.ps1` als generische Fassade verfügbar. CLI und Web-App rufen dieselben Funktionen auf.

## Konfiguration

Alle Pfade und Rollen kommen aus der aktiven `wb/config/v1`-Konfiguration:

- `store_root`
- `bindings[].locator` auf `RAW/files`
- `poc.source_root`, `poc.raw_root`, `poc.files`
- `poc.formats`
- `poc.queries`, `poc.evidence_allow`, `poc.evidence_limit`, `poc.query_limit`, `poc.search_limit`
- `poc.state_file`, `poc.synthesis_file`, `poc.log_file`
- `poc.source_space`, `poc.source_confidentiality`, `poc.source_organization`
- `poc.inventory_file` (optional, für Provenienz/Dubletten)

Es gibt keine kundenspezifischen Pfade oder Dokument-ID-Sonderabläufe im Code.

## Funktionen

| Funktion | Aufgabe |
| --- | --- |
| `Invoke-IngestionCapture` | kopiert die konfigurierten Dateien hashgeprüft nach `RAW/files` und erhält Dubletten-Herkunft |
| `Invoke-IngestionIndex` | registriert die Quelle und führt Import + Index-Neuaufbau aus |
| `Invoke-IngestionSynthesis` | KI-Synthese aus den übergebenen Belegen |
| `Build-IngestionPage` | validiert Belege und baut die Wissensseite |
| `Save-IngestionKnowledge` | legt die Seite mit Belegbasis und abgeleiteten Berechtigungen an |
| `Invoke-IngestionRun` | vollständiger Lauf: Aufnahme, Import/Index, belegte Synthese |
| `Start-IngestionJob` | startet den Lauf als Hintergrundprozess |
| `Get-IngestionJob` | liefert Status, Schritte, Fehler, Warnungen, Fortsetzbarkeit und Berechtigungen |
| `Resume-IngestionJob` | setzt denselben Job nach Fehler/Blockade fort |

CLI:

```powershell
# Neu
connector.ps1 ... -RunPoc -ConfirmExternalAi

# Wiederaufnahme
connector.ps1 ... -RunPoc -ResumePoc -ConfirmExternalAi
```

Web:

- `GET /poc/state`
- `POST /poc/run` mit `{ "confirmExternalAi": true, "resume": false }`
- `POST /poc/resume` mit `{ "confirmExternalAi": true }`

## Job-Zustand

Jeder Lauf besitzt:

- `jobId`, `attempt`, `resumeCount`
- `state`: `starting`, `running`, `completed`, `partial`, `failed`, `blocked`
- `steps` mit `pending/running/completed/failed/blocked`
- `error`, `lastError`, `warnings`
- `canResume` in der öffentlichen Statusantwort
- `permissions` der abgeleiteten Wissensseite

Die Wiederaufnahme verwendet denselben `jobId`, setzt fehlgeschlagene Schritte auf `pending` und führt die Pipeline idempotent weiter. Die Quellaufnahme bleibt lesend.

## Wissenslücken

Antworten liefern strukturierte `gaps` für Dokument-Nachweislücken. Die Oberfläche bietet je Lücke:

- `POST /kb/gap/inspect` — prüft, ob ein Dokument im aktiven Wissensraum vorhanden, extrahiert und indexiert ist
- `POST /kb/gap/add-file` — nimmt eine Datei ausschließlich im aktiven Wissensraum auf, prüft den Hash und importiert/indexiert sie; vorhandene Dokumente werden wiederverwendet
- `POST /kb/gap/link` — speichert einen HTTP(S)-Link als `linked_not_extracted`; kein Abruf und kein Import
- `GET /kb/gap/links` — listet verknüpfte Quellen

`inspect` verwendet die vorhandene Volltextsuche und Extraktionsmetadaten. Eine fehlende Datei wird nur als „Nicht im Bestand“ bezeichnet, wenn die Bestandsprüfung des Wissensraums vorliegt; sonst lautet die Aussage „In den gefundenen Belegen nicht enthalten“.

Nach erfolgreicher Aufnahme kann die ursprüngliche Frage erneut gestellt werden. Die alte Antwort, ihre Belege und die neue Antwort bleiben getrennt erhalten. Es wird dabei keine automatische Synthese oder Bestätigung ausgelöst.

## Berechtigungen

- Die Quelle wird mit `source_space`/`source_confidentiality` registriert.
- Jede Wissensseite wird mit `--basis` aus den tatsächlich verwendeten Fassungen angelegt.
- `wb` berechnet daraus `effective_space` und `effective_confidentiality` (strengste Quelle).
- `knowledge revise --basis` aktualisiert die Belegbasis und die abgeleiteten Berechtigungen bei einer neuen Fassung.
- Der Status weist `permissions` und `sourceAccess=read_only` aus.
