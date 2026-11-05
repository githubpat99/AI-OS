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

## Dokumentleser Und Volltextsuche

Dokumenttitel, Dateipfade und belegte Suchauszuege oeffnen einen rechten Leser, ohne Themenauswahl und aktuelle Suche zurueckzusetzen. Auf schmalen Bildschirmen nutzt der Leser die gesamte Breite; die Uebersicht bleibt im Hintergrund erhalten. Der Leser bietet Ueberschriftennavigation, eigene Suche mit hervorgehobenen Treffern und Trefferwechsel sowie Textbereichswechsel fuer grosse Inhalte. Er stellt nur Text dar, fuehrt keine importierten Skripte aus und laedt keine Bilder oder externen Links aus Dokumenten.

Die Hauptsuche durchsucht zusaetzlich die tatsaechlich gelesenen lokalen Volltexte. Treffer enthalten exakte Auszuege und Zeichenpositionen; nicht gelesene Inhalte liefern keine Volltextbelege. Metadaten-/Themenbelegtreffer bleiben separat moeglich. Pro Anfrage gelten maximal 300 Zeichen und 12 Suchwoerter; pro Dokument werden bis zu drei Textauszuege bereitgestellt. Keine KI-Zusammenfassungen oder erfundenen Antworten.

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
