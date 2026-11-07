# AI-OS-Themenlandkarte

Statische App mit festen Beispieldaten, rechtem Dokumentleser und einem getrennten lokalen Windows-Verbindungsdienst. Keine Cloud-Datenbank, keine externen Skripte in der App, kein Node erforderlich. Die erweiterte PDF-/OCR-, Office- und Mail-Extraktion verwendet eine isolierte lokale Python-Laufzeit.

## Lokal starten

Im AI-OS-Workspace-Stamm, Windows PowerShell 5.1:

```powershell
& .\themenlandkarte\setup-reader.ps1
& .\themenlandkarte\publish.ps1
& .\themenlandkarte\preview.ps1
```

Vorschau: http://127.0.0.1:43128. In einem zweiten Terminal:

```powershell
& .\themenlandkarte\connector.ps1 -Origin http://127.0.0.1:43128
```

In der App **AI-OS verbinden** waehlen. Die lokale Freigabeseite wird im selben Tab geoeffnet. **Verzeichnis freigeben** oeffnet die Windows-Ordnerauswahl. Danach kehrt der Browser zur App zurueck. Alternativ legt `-Root 'C:\Pfad\zum\AI-OS'` das freizugebende Verzeichnis beim Dienststart fest. Fuer ein anderes Verzeichnis erneut verbinden oder den Dienst mit anderem `-Root` starten.

**Aktualisieren** gleicht das Verzeichnis neu ab und liest geaenderte Inhalte neu ein. **Trennen** ersetzt den internen Index sofort durch Beispieldaten und leert Filter, Suche, Zuordnungen, Leser und Dialoginhalte. Verbindungsausfall oder Sitzungsablauf fuehren ebenfalls zur Demo; Status-/Aenderungspruefungen erfolgen bei geoeffneter verbundener App alle 2,5 Sekunden, mit bis zu 10 Sekunden Request-Timeout. Neuladen verbindet nicht automatisch erneut.

Erstaufbau und Aktualisieren laufen in einem lokalen PowerShell-Hintergrundauftrag. Die Freigabeseite beziehungsweise die App zeigen fuenf echte Phasen: Bestand erfassen, Inhalte lesen, Themen zuordnen, Wissensindex pruefen und Landkarte bereitstellen. Angezeigt werden bearbeitete/gesamte Arbeitsschritte, aktuelle Datei, Auswertungszaehler, Laufzeit, Alter der letzten Meldung und ein Phasenprotokoll. Prozentwerte gelten nur fuer die aktuelle Phase und erscheinen erst bei bekannter Gesamtzahl. Nach 15 Sekunden ohne neue Meldung erscheint ein Hinweis, kein vorgetaeuschter Fortschritt.

Nach erfolgreicher Aktualisierung klappt die Fortschrittsanzeige automatisch zu einer Statuszeile zusammen. Sie bleibt per Klick oder Tastatur aufklappbar, einschliesslich Phasen und Protokoll. Laufende Auftraege und Fehler werden offen angezeigt; abgeschlossene Schritte erhalten einen Haken. Die Themenzuordnung benennt ihre beiden Durchlaeufe: Textbelege/Dokumentrollen und dokumentierte Verweise zu Originalquellen.

Erstverbindung und Aktualisieren zeigen live Themen mit Beleg, Textzuordnungen, Verweiszuordnungen und Dokumente mit mindestens einem Thema. Dazu kommen die Zahl gepruefter Themenregeln und Dateiverweise, die aktuelle Themenregel sowie die drei zuletzt erkannten Themenlabels. Die Werte stammen aus dem laufenden Indexer und bleiben im Abschluss erhalten; es sind keine zeitbasierten Schaetzungen. Die eingeklappte Abschlusszeile nennt Themen- und Zuordnungszahl. Trennen entfernt auch diese Angaben. Es werden bis zu 19 fest definierte regelbasierte Themen erkannt, keine frei erfundenen neuen Themen.

Eine wachsende Themenuebersicht zeigt zusaetzlich pro Thema Dokumentanzahl als Balken, Text- und Verweisbelege sowie den Zustand der Pruefung. Der Balken vergleicht Dokumentanzahlen, nicht fachliche Vollstaendigkeit. Die aktuell gepruefte Regel ist hervorgehoben; Themen ohne Beleg bleiben als solche sichtbar. Filter **Nur Themen mit Beleg**, stabile Reihenfolge und erhaltene Scrollposition unterstuetzen die Beobachtung des Aufbaus. Erstverbindung und Aktualisieren verwenden dieselbe Komponente; Trennen leert auch diese Daten. Desktop-/Mobilanzeige, Filter und Leeren sind im Browser mit kuenstlichen Zwischenstaenden geprueft; die echten pro-Thema-Zaehler sind Bestandteil des Integrationstests.

Beim Aktualisieren bleibt der bisherige Index sichtbar und wird erst nach erfolgreicher Pruefung ersetzt. Ein gemeldeter Indexierungsfehler laesst ihn unveraendert; bei Verbindungsverlust werden interne Inhalte weiterhin entfernt. Kurze Statusabfragen ersetzen den bisherigen blockierenden Drei-Minuten-Request. Trennen beendet auch einen laufenden Hintergrundauftrag und leert Fortschrittsdaten und Protokoll.

## Wissensbasis-Client — Flurgenossenschaft-Pilot

Die bestehende App kann den vorhandenen zentralen Store als Client lesen. Der Dienst startet dabei **ohne Verzeichnisscan**; die Oberflaeche ruft ausschliesslich die lokale `wb`-Zugriffsschicht auf. Die App oeffnet keine SQLite-Datei und liest keine Store-Datei direkt.

```powershell
# Einmalig nach einer Codeaenderung: Build aus map.template.html
& .\themenlandkarte\publish.ps1

# Vorschau, falls noch nicht gestartet
& .\themenlandkarte\preview.ps1

# In einem zweiten Terminal: Store-Client statt Verzeichnisindex
& .\themenlandkarte\connector.ps1 `
  -Origin http://127.0.0.1:43128 `
  -WissensbasisConfig C:\AI-OS-Pilot\flurgenossenschaft\config.json
```

Danach `http://127.0.0.1:43128` oeffnen, **AI-OS verbinden** waehlen und auf der lokalen Freigabeseite **Wissensbasis verbinden** bestaetigen.

Die Kopfzeile zeigt **Echte Daten** mit Store-Pfad und Index-Build oder ausdruecklich **Beispieldaten**. Die Wissensbasis oeffnet beim Einstieg die Seite **Sanierung: Kosten, Honorar, Etappierung, Retention**.

Die Hauptansicht ist dreispaltig:

- **Links:** Themenbaum mit den vier kanonischen Wissensseiten und der Trefferliste der Suche.
- **Mitte:** lesbare Wissensseite mit einem Status, Aktionen und aufklappbaren Details für technische IDs, Fassung und Belegbasis; der Bestätigungsverlauf öffnet über **Bestätigt · Verlauf ansehen** beziehungsweise **Verlauf ansehen**.
- **Rechts:** Fragebereich dauerhaft oben mit **Frage abschicken** und Info-Schaltfläche; darunter **Quellen** mit hervorgehobenem Titel der Wissensseite und den bestehenden Quellen; darunter aufklappbare **Verwandte Wissensseiten**.

### Fragefunktion

Die Fragefunktion nutzt zuerst die vorhandene Volltextsuche im Store (`wb search`) und optional eine konfigurierte KI-Anbindung. Ohne KI antwortet sie mit einem Auszug aus der passenden, als unbestätigt markierten Wissensseite und nennt die Quellenbelege. Mit KI werden die abgerufenen Belegstellen als Kontext übergeben. Jede Antwort nennt abrufbare Belege (Datei, Fassung, Seite/Zeichenstelle); fehlende Informationen werden ausdrücklich ausgewiesen. Folgefragen berücksichtigen den bisherigen Verlauf (max. 12 Beiträge im UI, 6 im Prompt). Es sind keine Antworten fest hinterlegt.

Ablauf: Frage im rechten Bereich eingeben, **Frage abschicken**. Belege in der Antwort öffnen den Belegdialog; **Original abrufen** lädt die Datei über `wb original`. Im Retrieval-Modus ist die Antwort ausdrücklich als Auszug aus einer `needs_review`-Seite gekennzeichnet. Die lange Erklärung zur KI-/Retrieval-Nutzung liegt hinter der Info-Schaltfläche.

Eine KI-Anbindung ist optional:

```powershell
$env:DEEPSEEK_API_KEY = '...'
& .\themenlandkarte\connector.ps1 `
  -Origin http://127.0.0.1:43128 `
  -WissensbasisConfig C:\AI-OS-Pilot\flurgenossenschaft\config.json `
  -AiConfig C:\AI-OS-Pilot\flurgenossenschaft\ai.example.json
```

Unterstützt werden OpenAI-kompatible Endpunkte (`/chat/completions`) und Ollama (`/api/chat`); Schema `wb/ai/v1`. Ohne `-AiConfig` prüft der Connector `DEEPSEEK_API_KEY`/`OPENAI_API_KEY`; ohne Schlüssel bleibt der Retrieval-Modus aktiv. **Mit externer KI werden die abgerufenen Belegstellen an den konfigurierten Anbieter gesendet.** Das ist eine bewusste Freigabe und nicht Standard; für vertrauliche Inhalte ist ein lokaler Ollama-Endpunkt vorzuziehen. Für den dokumentierten Test ist DeepSeek lokal über `DEEPSEEK_API_KEY` konfiguriert; Ergebnisse und Grenzen stehen in `reports\KI-TEST-DEEPSEEK.md`. Schlüsselwerte werden weder angezeigt noch im Repository gespeichert.

Fünf fachliche Fragen und die Ergebnisse stehen in `C:\AI-OS-Pilot\flurgenossenschaft\reports\ask-five-ai.json` und `ask-five-ai-full.json`; der DeepSeek-Test ist in `reports\KI-TEST-DEEPSEEK.md` dokumentiert. Wiederholbar mit `.\themenlandkarte\test-five-questions.ps1` (Connector muss laufen).

Der Fragebereich zeigt jede abgesendete Frage dauerhaft direkt über ihrer Antwort; die neueste Frage steht oben. Während der Verarbeitung erscheinen Frage und **„Antwort wird erstellt …“** sofort; bei einem Fehler bleiben Frage und ein **Erneut senden**-Knopf erhalten. Frühere Paare bleiben bei Folgefragen stehen, jedes mit seiner eigenen Belegzuordnung. Quellenverweise wie `[E1]`, `(E1)` oder `E1` sind anklickbar und öffnen die Belegstelle mit hervorgehobener Zeichenspanne. Belege werden mit Dokumenttitel und Seite beschriftet; gefundene Rohtexte stehen pro Antwort in einem aufklappbaren Bereich. Antworten mit Markdown-Tabellen und Listen werden als Tabellen/Listen dargestellt.

**Architektur** ist eine eigene, rein lesende Ansicht innerhalb der App. Eine Übersicht zeigt die vier Schichten **Oberfläche, Zugriff, Logik, Daten** als verbundenes Systembild mit beschrifteten Datenflüssen; darunter erklären die Schichten ihre Komponenten im Detail. Statuswerte unterscheiden **Aktiv**, **Nicht verbunden**, **Nicht eingerichtet**, **Geplant** und **Unbekannt**. Komponenten sind anklickbar und erklären Aufgabe, Lese-/Schreibzugriffe sowie lokale oder externe Verarbeitung. Adressen und Datenstände stammen aus der aktuellen Sitzung; interne Pfade erscheinen erst nach autorisierter Verbindung, Zugangsdaten nie.

**Quellen zur Wissensseite** stehen rechts in einem eigenen, vom Chat getrennten Bereich. Der Quellenkopf nennt nur die Anzahl der **Quelldokumente**. Jedes Dokument erscheint mit sprechendem Titel und der **verwendeten Seitenangabe**, zum Beispiel **Budget 2024/2025 · S. 1** oder **HV43 Protokoll 2025 · S. 4–6**. Darunter stehen **Verwendete Seiten** als deduplizierte Bereiche; **Verwendete Fundstellen** öffnen ausschliesslich die für diese Wissensseite belegten Seiten/Abschnitte. **Gesamtes Dokument ansehen** öffnet den vollständigen ausgelesenen Text, **Original öffnen** die hashgeprüfte RAW-Datei. Kennung, Inhalts-Hash, Pfad und Fassungs-ID stehen unter **Details**. Der Belegdialog zeigt die Kette **Originalquelle aus RAW → ausgelesene Seite/Abschnitt → zugehörige Wissensseite**. Der Store führt kein separates Dokumenttitel-Feld; die Anzeige verwendet eine vorhandene Abschnittsüberschrift mit Dokumentkennung, sonst den Dateinamen. Zitate im Seitentext sind direkt anklickbar. **Quellen & Betrieb** enthält zusätzlich eine globale Ansicht nach Wissensseiten; gemeinsam verwendete Quellen erscheinen unter jeder Seite. Quellen einer Chatantwort stehen separat unter **„Für diese Antwort verwendet“** und können von den Seitenquellen abweichen.

**Bearbeiten und Bestätigen** sind getrennte Vorgänge. **Wissensseite bearbeiten** öffnet einen Texteditor für die aktuelle Fassung. Beim Speichern legt der Connector über die vorhandene `wb`-Versionierung (`wb knowledge revise`) eine **neue Fassung** an; Titel und Seiten-ID bleiben unverändert, die bisherige Fassung und ihre Bestätigung bleiben erhalten und die neue Fassung steht auf **Zu bestätigen**. Die Belegbasis wird beim Speichern technisch gegen den geladenen Stand geprüft. **Ansicht aktualisieren** liest dagegen nur den Store neu und legt keine Fassung an.

**Fachlich bestätigen** ist im `leader`-Modus ein einstufiger Dialog mit vier verpflichtenden Prüfpunkten, darunter ausdrücklich: „Ich habe diese Fassung und ihre Belegzuordnungen geprüft. Die Bestätigung ist keine Genehmigung der beschriebenen Vorhaben.“ Die Notiz ist optional; die Identität stammt aus der Store-Anmeldung (`owner`) und wird nicht als Freitext erfasst. Fehlende Prüfpunkte werden vor dem Absenden als **„Noch N Prüfpunkte offen“** am Prüfbereich und im Dialog benannt. Der Server prüft Anzahl und Basis-Hash erneut und ruft `wb review confirm` auf; bei Änderungen wird die Bestätigung erneut prüfbedürftig (`confirmation_stale`).

**Überarbeitung anfordern** ist ein eigener Dialog ohne Prüfpunkte. Eine konkrete Begründung ist Pflicht; fehlt sie, erscheint der Fehler direkt am Feld. Der Server ruft `wb review reject` auf. Beide Dialoge behalten Eingaben bei Validierungsfehlern. **Verlauf ansehen** öffnet den chronologischen Bestätigungsverlauf mit Datum, Identität, verständlicher Fassungsnummer und Begründung; technische IDs stehen unter **Details**, ältere Fassungen sind direkt lesbar. Eine bestätigte Fassung bleibt auch nach einer Überarbeitung nachweisbar; die neue Fassung muss erneut bestätigt werden. Keine automatische Bestätigung durch die KI, kein Sammel-Confirm.

Die linke Leiste zeigt pro Wissensseite **Bestätigt / Zu bestätigen / Überarbeitung nötig / Überholt** mit Datum und Identität; die Seiten sind direkt anklickbar. Bestätigt wird die Wissensseite als Ganzes, nicht jeder Beleg einzeln.

Verknuepfungen stammen aus vorhandenen Belegen (gemeinsame Fassung) oder werden als **automatisch vorgeschlagen** markiert; es werden keine neuen Inhalte oder bestaetigten Beziehungen erfunden.

**Quellen & Betrieb** ist der separate Bereich fuer Quellenstatus, Auswertungsregister, Element-/Fassungsliste und Originalzugriff. Die frueheren Tabs **Quellen** und **Auswertung** werden im Store-Modus ausgeblendet; die Ansicht ist schreibgeschuetzt.

Ablauf `Strassensanierung → Wissensseite → Beleg → Originalstelle`:

1. Im Suchfeld **Strassensanierung** eingeben (oder `?q=Strassensanierung` oeffnen).
2. In den Treffern die Wissensseite **Sanierung: Kosten, Honorar, Etappierung, Retention** waehlen.
3. Unter **Quellen** eine Quelle oder in einem Belegtreffer **Beleg** waehlen.
4. Im Dialog **Belegstelle** Datei, Fassung, Seite und den extrahierten Text pruefen; bei Suchtreffern wird die exakte Zeichenstelle angezeigt.
5. **Originaldatei abrufen** laedt die Datei ueber die `wb`-Zugriffsschicht aus RAW (Hash-Pruefung). Der Belegdialog zeigt extrahierten Text, keine Originalbytes.

Direkte Links nach der Verbindung:

- `?q=<suchbegriff>` startet die Suche.
- `?view=kbmap` oeffnet die visuelle Themenkarte.
- `?view=operations` oeffnet **Quellen & Betrieb**.
- `?evidence=<version-id>&page=<seite>` oeffnet den Belegdialog.

**Nicht implementiert:** semantische Suche. Die Ansicht zeigt extrahierten Text, keine Originalbytes. Die Wissensseiten-Bearbeitung legt neue Fassungen über `wb knowledge revise` an; die Suche wird dabei nicht automatisch neu indexiert.

## Dokumentleser Und Volltextsuche

Dokumenttitel, Dateipfade und belegte Suchauszuege oeffnen einen rechten Leser, ohne Themenauswahl und aktuelle Suche zurueckzusetzen. Auf schmalen Bildschirmen nutzt der Leser die gesamte Breite; die Uebersicht bleibt im Hintergrund erhalten. Der Leser bietet Ueberschriftennavigation, eigene Suche mit hervorgehobenen Treffern und Trefferwechsel sowie Textbereichswechsel fuer grosse Inhalte. Er stellt nur Text dar, fuehrt keine importierten Skripte aus und laedt keine Bilder oder externen Links aus Dokumenten.

Die Hauptsuche durchsucht zusaetzlich die tatsaechlich gelesenen lokalen Volltexte. Treffer enthalten exakte Auszuege und Zeichenpositionen; nicht gelesene Inhalte liefern keine Volltextbelege. Metadaten-/Themenbelegtreffer bleiben separat moeglich. Pro Anfrage gelten maximal 300 Zeichen und 12 Suchwoerter; pro Dokument werden bis zu drei Textauszuege bereitgestellt. Im Verzeichnismodus gibt es keine KI-Zusammenfassungen; die optionale KI-Anbindung des Wissensbasis-Clients ist oben getrennt beschrieben.

**In VS Code bearbeiten** oeffnet freigegebene Textformate nach ausdruecklichem Klick in der lokal installierten VS-Code-Anwendung. **In zugehoeriger Anwendung oeffnen** verwendet nach ausdruecklichem Klick die lokale Standardanwendung. Es gibt keinen eingebauten Editor und keine Schreibschnittstelle fuer Dokumentinhalte. Beide Aktionen laufen als authentifizierter POST ueber die lokale Verbindung; Statusabfragen starten niemals eine Anwendung. Geaenderte, aber weiterhin freigegebene Originale duerfen zum Korrigieren geoeffnet werden.

**Herunterladen** stellt die Originalbytes ueber die token-geschuetzte Verbindung bereit; der Browser bestimmt den Speicherort. Fuer den Download muss der Inhalt zum gelesenen Indexstand passen; geaenderte Dateien werden bis zur erfolgreichen Aktualisierung abgelehnt. Pfadausbrueche, Zugangsdatenkandidaten und symbolische Verweise werden fuer alle Originalaktionen abgelehnt. Kein Token in Download-URLs. Externe Standardanwendungen und deren Dokument-/Makrosicherheit liegen ausserhalb der App.

## Speichern Und Dokumentstaende

Der lokale Dienst ueberwacht das freigegebene Verzeichnis mit einem Dateisystem-Watcher. Die geoeffnete App fragt den Zustand alle 2,5 Sekunden ab. Nach dem Speichern startet bei erkannter Aenderung ein Hintergrundabgleich; nur Dateien mit geaendertem Inhalts-Hash oder fehlerhaftem Vorlauf werden erneut extrahiert. Unveraenderte gelesene Inhalte werden innerhalb der Sitzung wiederverwendet. Themenzuordnung und Verweise werden fuer einen konsistenten Gesamtindex neu berechnet. Weitere Aenderungen waehrend eines Auftrags werden anschliessend abgeglichen. Der geoeffnete Leser prueft den SHA-256-Hash zusaetzlich zum Watcher auch dann, wenn Dateidatum und Groesse gleich geblieben sind. **Aktualisieren** bleibt fuer einen ausdruecklichen vollstaendigen Verzeichnisabgleich verfuegbar. Bei Browser- oder Systempause erfolgt die Verarbeitung mit der naechsten Statusabfrage.

Nach erfolgreicher Uebernahme wird die Themenlandkarte automatisch aktualisiert. Themenauswahl, Hauptsuche, geoeffneter Leser und Dokumentsuche bleiben erhalten, soweit die zugehoerigen Themen und Dateien weiterhin bestehen. Der Leser zeigt getrennt:

- Aenderungszeit der aktuellen Quelldatei und deren aktuellen Inhalts-Hash.
- Zeitpunkt der letzten erfolgreichen Auswertung, den damals gelesenen Quellzeitpunkt und Index-Hash.
- Zeitpunkt des letzten erfolgreich uebernommenen Verzeichnisabgleichs.

Alle angezeigten Datums-/Uhrzeitwerte werden explizit mit `Europe/Zurich` formatiert, einschliesslich Sommer-/Winterzeit; gespeicherte Werte sind UTC-Zeitpunkte. Quelle und Index gelten nicht allein wegen gleicher Dateidaten als identisch: der Inhalts-Hash entscheidet zusaetzlich. Die Zustaende **Aktuell**, **Veraltet**, **Verarbeitung laeuft** und **Fehler** werden sichtbar unterschieden. Ein reiner Abgleich unveraenderter Inhalte erzeugt keinen neuen erfolgreichen Auswertungszeitpunkt.

Bei fehlgeschlagener Verarbeitung bleibt der letzte erfolgreiche Auswertungszeitpunkt unveraendert. Innerhalb der aktiven Sitzung bleibt ein vorhandener erfolgreicher Text mit klarer Veraltet-/Fehlerkennzeichnung lesbar. Fehlgeschlagene Dateien werden nicht als neue erfolgreiche Auswertung ausgegeben. Ein entfernter Quellpfad verschwindet aus aktuellen Suchtreffern; ein bereits geoeffneter letzter Stand erhaelt einen Fehlerhinweis. Es erfolgt kein endloses automatisches Wiederholen desselben unveraenderten Fehlerstands; erneutes Speichern oder **Aktualisieren** erlaubt einen neuen Versuch.

Zeitpunkte, Hashes, Pfade und Fehlerstatus werden pro freigegebenem Verzeichnis unter `%LOCALAPPDATA%\AI-OS\Themenlandkarte\state\` gespeichert, nicht im GitHub-Repository. Diese dauerhafte Historie enthaelt keinen Volltext und kein Verbindungstoken. Sie behaelt erfolgreiche Auswertungszeitpunkte auch nach einem Dienstneustart; Inhalte muessen nach neuer Freigabe erneut lokal gelesen werden. Trennen entfernt die aktuelle Browser-/Verbindungsansicht, nicht die ausdruecklich gefuehrte private Metadatenhistorie.

**Zum Dokument fragen** ist sichtbar vorbereitet, aber deaktiviert und ausdruecklich als noch nicht verfuegbar gekennzeichnet. Es besteht keine KI-Anbindung; es werden keine Dokumente an KI-Dienste gesendet.

## Lokale Extraktion

`setup-reader.ps1` installiert Python, Parser und mitgelieferte OCR-Modelle unter `%LOCALAPPDATA%\AI-OS\Themenlandkarte`, ohne Administratorrechte. Nur die Installation braucht Internet fuer Pakete; die Inhaltsverarbeitung erfolgt lokal. Windows-Systemproxy und Zertifikatsspeicher werden beruecksichtigt. Ohne diese Laufzeit bleibt UTF-8-Text lesbar; andere Formate melden die fehlende Extraktion explizit, Office hat einen gekennzeichneten XML-Rueckfall.

- Markdown, Text, YAML, JSON und CSV: vollstaendiger UTF-8-Text innerhalb der Dateigroessengrenze.
- HTML: lesbarer Text und Ueberschriften ohne Script-/Style-Ausfuehrung und ohne Bilder; teilweise ausgelesen.
- PDF: lokaler Textparser; textarme oder bildbasierte Seiten erhalten lokales OCR. OCR-Fehler, ungelesene Seiten und Erkennungsunsicherheit bleiben im Status sichtbar. Maximal 80 Seiten und acht OCR-Seiten pro PDF, maximal 1500000 Textzeichen. PDF bleibt teilweise ausgelesen, weil Layout, Bilder und Tabellen nicht vollstaendig interpretiert werden.
- DOCX, XLSX, PPTX: Text, Tabellenzellen, Folien und verfuegbare Notizen; Formeln als Ausdruck, nicht als berechnetes Ergebnis. Bilder, Makros, Layout und eingebettete Objekte nicht vollstaendig ausgewertet. XLSX begrenzt auf 10000 Zeilen und 200 Spalten pro Blatt. Teilweise ausgelesen.
- EML und MSG: Nachrichtenkopf und Nachrichtentext, keine Anhangsinhalte oder eingebetteten Bilder. MSG hat einen sichtbaren Windows-1252-Kodierungsrueckfall. Teilweise ausgelesen.
- RTF: Text ohne Bilder oder eingebettete Objekte. Alte binaere Office- und OpenDocument-Formate sind in dieser Stufe nicht unterstuetzt und bleiben als nicht ausgelesen sichtbar.

Der Parser hat ein Zeitlimit von 120 Sekunden pro Datei. Verschluesselte, beschaedigte, leere oder nicht unterstuetzte Dokumente werden nicht als erfolgreich gelesen ausgewiesen. Dateien ueber 8 MiB bleiben ausgenommen. Der Leser zeigt pro Dokument den Status **vollstaendig**, **teilweise** oder **nicht ausgelesen** und den konkreten Grund. Inhalte werden nicht als fachlich vollstaendig verstanden oder zusammengefasst behauptet.

## GitHub Pages

`publish.ps1` liest keine internen Verzeichnisse. Es erzeugt [public/index.html](public/index.html), eine leere `.nojekyll` und einen Pages-Workflow. Unbekannte Dateien im Ausgabeordner stoppen den Build.

1. Ein oeffentliches GitHub-Repository fuer die App festlegen. Bestehende Basisdateien unveraendert lassen. Niemals den internen AI-OS-Workspace oder dessen Git-Historie veroeffentlichen.
2. Ausschliesslich den Inhalt von `themenlandkarte/public/` als Repository-Inhalt veroeffentlichen, einschliesslich `.github/workflows/pages.yml`.
3. Unter Settings > Pages als Source **GitHub Actions** auswaehlen. Der Workflow reagiert auf `main` und kann manuell gestartet werden; er stellt nur `index.html` und `.nojekyll` bereit.
4. Nach erfolgreicher Bereitstellung den Dienst mit dem exakten HTTPS-Ursprung starten, zum Beispiel:

```powershell
& .\themenlandkarte\connector.ps1 -Origin https://githubpat99.github.io
```

Der Repository-Pfad gehoert nicht zu `-Origin`. Fuer eine eigene Domain deren Ursprung verwenden. Auf einem Pages-Ursprung keine fremden oder nicht vertrauenswuerdigen Apps betreiben: Browser-Isolation und Freigabe gelten pro Ursprung, nicht pro Repository-Pfad.

**Bereitstellungsstand:** Das oeffentliche Paket wurde mit Commit `2565d04` nach https://github.com/githubpat99/AI-OS uebertragen; bestehende Basisdateien blieben unveraendert. Deployment-Lauf `41978114842` ist erfolgreich abgeschlossen. Externe Editoraktionen, automatische Aktualisierung nach Speichern und getrennte Dokument-/Indexstaende sind unter https://githubpat99.github.io/AI-OS/ verfuegbar. Neuer Public-Build, explizite Zurich-Zeitdarstellung, HTTPS-Zugriff auf den aktualisierten lokalen Dienst und Ablehnung von Editoraktionen ohne Freigabe sind im Browser geprueft. Bereits geoeffnete Seiten neu laden und erneut verbinden. Interne Inhalte, private Historie und Dienstcode wurden nicht veroeffentlicht.

## Datenschutz Und Grenzen

- Der Dienst lauscht ausschliesslich auf `127.0.0.1:43127`, ohne Administratorrechte. Keine Freigabe im LAN erforderlich.
- CORS erlaubt genau einen konfigurierten Ursprung. Host-Pruefung, lokale Nonce-Freigabe, 256-Bit-Sitzungstoken und acht Stunden Sitzungsdauer schuetzen den Index. Fremde Rueckkehradressen werden abgelehnt.
- Das Token wird im URL-Fragment zur App zurueckgegeben, nicht als HTTP-Query an GitHub gesendet und sofort aus der Adresszeile entfernt. Index und Token liegen nur im Arbeitsspeicher der Seite, nicht in Local-/Session-Storage oder Service-Worker-Caches. Alter Zuordnungsspeicher wird entfernt.
- Beim expliziten Trennen wird der lokale Token widerrufen. Beim Schliessen versucht die App ebenfalls einen Widerruf; bei Browser-Abbruch ist dieser nicht garantiert. Dienst beenden widerruft alle Sitzungen.
- Private Index- und Textdateien entstehen voruebergehend ausserhalb des Workspaces im Windows-Temp-Verzeichnis und werden nach erfolgreicher Uebernahme geloescht. Bei einem Fehler koennen sie dort bis zum geordneten Dienstende verbleiben. Der Dienst liest Originale nur und bietet ausschliesslich authentifizierten Dokumentzugriff und Originaldownload; keine Schreibschnittstelle.
- Die vertrauenswuerdige oeffentliche App verarbeitet interne Titel, Pfade, gelesenen Text und Belege im Browser. Diese sind nicht anonymisiert. Ein kompromittierter Seiten-Ursprung, lokale Schadsoftware oder Browsererweiterungen liegen ausserhalb dieses Schutzmodells. Keine Telemetrie oder externen Inhaltsanfragen. Trennen leert Reader, Suchbelege und Volltextablage; bereits bewusst gespeicherte Originaldownloads koennen nicht zurueckgerufen werden.
- Ein bewusster Zuordnungsexport enthaelt interne Pfade. Solche Exporte nicht in das oeffentliche Repository aufnehmen.
- Die bisherige private HTML-/Index-Ausgabe wurde unter `%LOCALAPPDATA%\AI-OS\Themenlandkarte-Backup-*` gesichert. Sie ist kein Bestandteil des Public-Pakets.

## Pruefung

```powershell
& .\themenlandkarte\test.ps1
& "$env:LOCALAPPDATA\AI-OS\Themenlandkarte\runtime\Scripts\python.exe" .\themenlandkarte\tests\test_extraction.py -v
```

Automatisierte Integrationstests starten einen separaten Dienst auf Port 43129 mit [tests/fixture/sample.md](tests/fixture/sample.md). Geprueft werden CORS, Authorization-/Private-Network-Preflight, unberechtigte Requests, fremde Urspruenge und Rueckkehradressen, lokale Freigabe, echter Index, Aktualisieren, Widerruf und Public-Isolation. Keine internen Quellen erforderlich.

Editor-/Standpruefungen arbeiten mit temporaeren Kopien: unveraenderte Auswertungszeitpunkte, Hash-Aenderung bei gleichem Dateidatum, automatisches Neueinlesen nach Speichern, Fehler mit Erhalt des letzten Erfolgszeitpunkts und Textes, entfernte Quelldatei, private Historie ohne Volltext sowie Schutz des VS-Code-Endpunkts. Browsergeprueft: ausdruecklicher VS-Code-Klick, automatische Aktualisierung von Leser und Themenlandkarte, Erhalt von Themen-/Suchzustand, Fehleranzeige und Hashabweichung, Zurich-Winter-/Sommerzeit, Lesergrenzen auf Desktop/Mobil und Leeren der Zeit-/Hashfelder beim Trennen. Die integrierte Browseraufnahme konnte nach Fokuswechsel zeitweise den Hintergrund statt des Lesers zeigen; die mobilen Viewportgrenzen und verfuegbare Leseflaeche wurden zusaetzlich direkt im Browser geprueft.

Zusaetzlich geprueft: alle fuenf Fortschrittsphasen, lokale Statusabfragen ohne Origin-Header mit Nonce, Token-Schutz beim Aktualisieren, erreichbarer Dienst und lesbarer bisheriger Index waehrend eines Auftrags, Ablehnung doppelter Auftraege sowie Trennen waehrend einer Aktualisierung. Browserpruefung mit Testdaten: Erstverbindung, Fortschrittsanzeige und Abschluss beim Aktualisieren, Desktop-/Mobilbreite und vollstaendiges Leeren beim Trennen.

Optimierung vom 04.11.2026: Die Belegsuche verwendet die einmal normalisierten Dokumentzeilen wieder, statt sie pro Themenregel erneut zu normalisieren. Vergleich mit der bisherigen Suchschleife an einem kuenstlichen Text mit 801 Zeilen und 19 Themen: vollstaendig identische Zuordnungen und Belege; 1264 ms bisher, 143 ms optimiert. Das ist eine Teilmessung, keine neunfache Beschleunigung des gesamten Aufbaus. Ein vollstaendiger lokaler Aufbau mit 1079 Dateien und 19 Themen dauerte 153,18 s, davon 147,54 s Themenzuordnung. Automatisches Einklappen, manuelles Aufklappen, Erhalt bewusst geoeffneter Details, Abschlusshaken und Mobilbreite im Browser geprueft.

Weitere Pruefung am 04.11.2026: Dokumentzeilen, Ueberschriften und Verweiskontexte werden pro Dokument zwischengespeichert. Der Integrationstest prueft zwei Verweise unter verschiedenen Ueberschriften anhand einer kuenstlichen [Originalquelle](tests/fixture/source.eml). Die Live-Zaehler wurden am fertigen Gesamtindex gegengeprueft: 1079 Dateien, 19 Themen, 765 Textzuordnungen, 146 Verweiszuordnungen und 396 Dokumente mit Thema. Alle Zaehler stimmen ueberein. Gesamtlaufzeit dieser Messung: 165,02 s; eine zusaetzliche Gesamtbeschleunigung ist damit nicht belegt. Desktop-/Mobilanzeige der Live-Zaehler, Abschlussbilanz und Leeren beim Trennen sind im Browser mit kuenstlichen Testwerten geprueft; echte Zaehler und Verweisbelege zusaetzlich im Integrationstest und lokalen Gesamtaufbau.

Am 04.11.2026 fruehzeitig im verwendeten VS-Code-Browser getestet: Windows, VS Code 1.144.1, Chromium 150 / Electron 43. Von der real geladenen HTTPS-Seite `https://octocat.github.io/` erreichten sowohl ein einfacher Fetch als auch ein Fetch mit Authorization-Header den Loopback-Dienst mit HTTP 200. Keine Abschaltung von Browserschutzmechanismen. Dies war ein Transporttest, keine Veroeffentlichung dieser App auf der fremden Seite. Andere Browser und Unternehmensrichtlinien koennen eine lokale Netzwerkfreigabe verlangen oder den Zugriff sperren. Der Fehler wird in der App angezeigt; kein stiller Sicherheits-Workaround.

## Indexmethode

Am 04.11.2026 zusaetzlich die veroeffentlichte App unter `https://githubpat99.github.io/AI-OS/` im selben Browser end-to-end mit kuenstlichen Testdaten geprueft: lokale Freigabe und Rueckkehr zur HTTPS-App, Indexanzeige mit Verzeichnis und Zeitstempel, entferntes Token-Fragment, Aktualisieren mit HTTP 200 sowie Trennen mit bestaetigtem Widerruf (HTTP 200). Danach nur Beispieldaten, kein Testtitel und kein verbundenes Verzeichnis mehr sichtbar. Keine internen Quellen fuer diesen Test verwendet.

Der vorhandene regelbasierte Indexer wird weiterverwendet: 19 Themenkandidaten, textgestuetzte automatische Vorschlaege, getrennte Dokumentrollen und dokumentierte Verweiszuordnungen. Keine semantische Vollpruefung. Parser und Grenzen stehen unter **Lokale Extraktion**. Dateien ueber 8 MiB, Zugangsdatenkandidaten und technische Verzeichnisse werden ausgelassen. Symbolic Links/Junctions werden nicht verfolgt; normale OneDrive-Cloud-Dateien bleiben lesbar. Ein gesondertes `documents.json` mit gelesenen Texten liegt nur im privaten Ausgabeverzeichnis; der Metadatenindex enthaelt keinen Volltext.

Fuer einen privaten Diagnoseindex muss ein Ausgabeverzeichnis ausserhalb des eingelesenen AI-OS und ausserhalb dieser App angegeben werden:

```powershell
& .\themenlandkarte\build.ps1 -Root 'C:\Intern\AI-OS' -OutputDirectory "$env:LOCALAPPDATA\AI-OS\PrivaterIndex"
```

`-IndexOnly` enthaelt zusaetzlich gelesenen Volltext im Index und ist ausschliesslich fuer private lokale Diagnosen bestimmt. Auch die private Textablage niemals veroeffentlichen.

Reader-Pruefung vom 04.11.2026: neun lokale Extraktionstests einschliesslich echter OCR, Office, MIME-Anhaengen und MSG-Kodierungsrueckfall bestanden. Der vorhandene MSG-Fall wird mit sichtbarem Kodierungshinweis gelesen. Vollstaendiger Aufbau: 1079 Dateien, 597 mit lesbarem Text; 81 PDFs teilweise, drei nicht ausgelesen; Office 29 teilweise, eine Praesentation nicht ausgelesen; Mail 116 teilweise, zwei nicht ausgelesen. Gesamtdauer 286,69 s mit zusaetzlicher PDF-/OCR-Verarbeitung. Die korrigierte Regex-Bereinigung senkte die vorher gemessene Textaufbereitung auf 1,13 s. Volltext blieb ausschliesslich in der privaten Textablage. Browsergeprueft: Themen-/Suchzustand bleibt beim Oeffnen erhalten, Ueberschriften und Treffer, keine Script-Ausfuehrung aus Dokumenttext, Reader auf Desktop und Mobil, Originalbytes und Leeren beim Trennen. Der integrierte Browser lieferte kein automatisierbares Downloadereignis; die tatsaechlich an die Downloadaktion uebergebenen Bytes und der lokale Download-Endpunkt wurden geprueft.
