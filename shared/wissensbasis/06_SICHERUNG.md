# 06 — Sicherung der ungesicherten Quellen und unversionierten Inhalte

Stand: 2026-11-05 · Vorschlag, **nicht ausgeführt** · Keine Datei verschoben, kein Backup angelegt.

**Hinweis zum Pilot:** Im Profil-A-Lauf wurde `wb backup`/`restore` für den Store auf demselben Laufwerk `C:` getestet. Das belegt Wiederherstellbarkeit, **nicht** Schutz vor Festplattenausfall. Die hier beschriebenen Git-Bundles, Mailarchiv- und Offsite-Sicherungen wurden nicht ausgeführt.

## 1. Befund (gemessen 2026-11-05)

| Bestand | Größe / Umfang | Versionierung | Sicherung heute |
| --- | --- | --- | --- |
| `AI-Consulting-OS/local-only/mail-archive/test/` | 6 210 EML (835 MB), 5 644 `.bin`-Anhänge (481 MB), `mail-index.sqlite3` (74.5 MB) | `.gitignore` (`local-only/`) | **keine** – weder Git noch Remote |
| `AI-Engineering-OS` Organisationsebene (`AGENTS.md`, `CURRENT_STATE.md`, `INDEX.md`, `briefs/`, `Engineering.code-workspace`) | wenige Dateien, < 0.1 MB | **keine** (Parent ignoriert den Ordner, kein eigenes Repo) | **keine** |
| `AI-Engineering-OS/projects/*` lokale Änderungen | pensionierungsplanung 2, vermoegensplanung 1, next-app 11 geänderte/neue Dateien | eigene Repos, alle Commits gepusht (`ahead=0`) | uncommitted Änderungen **nicht** gesichert |
| Parent `AI-OS` | 33 getrackte Dateien, 11 lokale Änderungen (Themenlandkarte, Entwurfsdokumente) | eigenes Repo, gepusht | uncommitted Änderungen **nicht** gesichert |
| `AI-Consulting-OS` | 744 getrackte Dateien | eigenes Repo, gepusht (`ahead=0`) | Remote vorhanden; kein unabhängiges Offline-Backup belegt |
| `AI-Private-OS` | 318 getrackte Dateien inkl. 117 EML und 50 PDF | eigenes privates Repo, gepusht (`ahead=0`) | Remote vorhanden; kein unabhängiges Offline-Backup belegt |
| Wissensbasis-Store (neu) | noch nicht angelegt | — | entfällt bis zur Freigabe |

Freier Speicher: C: 52.9 GB, D: 3.1 GB (30 GB), G: 8.6 GB (15 GB). OneDrive ist vorhanden. Ein dediziertes externes Ziel ist nicht belegt; G: reicht für einen ersten Offline-Satz, nicht für dauerhafte Rotation.

**Kernaussage:** Die Mail-Rohdaten (1.3 GB) und die Engineering-Organisationsunterlagen sind die einzigen Bestände ohne jede Sicherung. Die Git-Repositories sind gepusht, aber nicht unabhängig gesichert; uncommittete Arbeit ist in keinem Backup.

## 2. Grundsätze

1. **3-2-1:** mindestens drei Kopien, zwei Medien, eine räumlich getrennte Kopie.
2. **Originale bleiben unverändert.** Sicherung ist Kopieren, nie Verschieben oder Überschreiben.
3. **Privatdaten verschlüsselt außer Haus.** BitLocker-verschlüsseltes USB-Laufwerk oder 7z-Archiv mit AES-256; Passphrase im Windows Credential Manager, nie im Repository oder in OneDrive-Dateien.
4. **Keine aktive SQLite-Datenbank in OneDrive.** Nur eingefrorene, geprüfte Archive dürfen dorthin; Wiederherstellung immer zuerst lokal.
5. **Wiederherstellbarkeit prüfen, nicht annehmen.** Jede Sicherung erhält eine SHA-256-Liste; vierteljährlich wird stichprobenartig zurückgespielt.
6. **Keine Sicherung in Git-Repositories.** Sie würde private Daten in den falschen Historiekontext schreiben.

## 3. Zielstruktur

```
<Backup-Ziel>/AI-OS-Backups/
  2026-11/
    daily/
      2026-11-05/
        git/
          ai-os.bundle
          ai-consulting-os.bundle
          ai-private-os.bundle
          pensionierungsplanung.bundle
          vermoegensplanung.bundle
          next-app.bundle
          bundles.sha256
        unversioned/
          engineering-os-docs.zip
          parent-worktree.patch
          engineering-projects.patch
        mail-archive/
          extracted/…
          attachments/…
          originals/…
          mail-index.sqlite3
          mail-manifest.sha256
        store/
          wissensbasis-backup/…        (wb backup: db/, blobs/, journal/, backup.json)
        backup-report.json
    weekly/
      2026-W45/…
    monthly/
      2026-11/…
```

Empfohlenes Ziel: externes USB-Laufwerk mit ≥ 128 GB, BitLocker-verschlüsselt, alternierend zwei Datenträger (einer ausgelagert). Interim: `G:\AI-OS-Backups` (8.6 GB frei) für einen ersten Satz; `D:` ist mit 3.1 GB zu knapp.

## 4. Konkrete Schritte (nicht ausgeführt)

Alle Befehle sind kopierbar. `$Backup` steht für das Ziel, z. B. `G:\AI-OS-Backups\2026-11\daily\2026-11-05`.

### 4.1 Git-Bundles aller Repositories

```powershell
$Backup = 'G:\AI-OS-Backups\2026-11\daily\2026-11-05'
New-Item -ItemType Directory -Force "$Backup\git" | Out-Null

$repos = @{
  'ai-os'                  = 'C:\Users\patri\AI-OS'
  'ai-consulting-os'       = 'C:\Users\patri\AI-OS\AI-Consulting-OS'
  'ai-private-os'          = 'C:\Users\patri\AI-OS\AI-Private-OS'
  'pensionierungsplanung'  = 'C:\Users\patri\AI-OS\AI-Engineering-OS\projects\pensionierungsplanung'
  'vermoegensplanung'      = 'C:\Users\patri\AI-OS\AI-Engineering-OS\projects\vermoegensplanung'
  'next-app'               = 'C:\Users\patri\AI-OS\AI-Engineering-OS\projects\next-app'
}
foreach ($name in $repos.Keys) {
  git -C $repos[$name] bundle create "$Backup\git\$name.bundle" --all
  git -C $repos[$name] bundle verify "$Backup\git\$name.bundle"
}
Get-ChildItem "$Backup\git\*.bundle" | ForEach-Object {
  "$($_.Name)  $((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
} | Set-Content "$Backup\git\bundles.sha256"
```

Ein Bundle enthält **nur committete** Objekte. Uncommittete Änderungen müssen vorher Committet oder als Patch gesichert werden.

### 4.2 Unversionierte Engineering-Organisation und lokale Änderungen

```powershell
# Organisationsebene ohne die Code-Repositories
$eng = 'C:\Users\patri\AI-OS\AI-Engineering-OS'
Compress-Archive -Path @(
  "$eng\AGENTS.md", "$eng\CURRENT_STATE.md", "$eng\INDEX.md",
  "$eng\Engineering.code-workspace", "$eng\briefs"
) -DestinationPath "$Backup\unversioned\engineering-os-docs.zip" -Force

# Uncommittete Änderungen als Patch (nur Text; Binärdateien separat prüfen)
git -C 'C:\Users\patri\AI-OS' diff --binary > "$Backup\unversioned\parent-worktree.patch"
git -C 'C:\Users\patri\AI-OS' ls-files --others --exclude-standard |
  ForEach-Object { Copy-Item (Join-Path 'C:\Users\patri\AI-OS' $_) "$Backup\unversioned\parent-untracked\" -Force }
foreach ($p in @('pensionierungsplanung','vermoegensplanung','next-app')) {
  git -C "C:\Users\patri\AI-OS\AI-Engineering-OS\projects\$p" diff --binary > "$Backup\unversioned\$p-worktree.patch"
}
```

Empfehlung: Die Engineering-Organisationsebene sollte dauerhaft ein eigenes privates Repository erhalten (Entscheidung des Nutzers, **kein** Zusammenlegen). Bis dahin ist das ZIP die Sicherung.

### 4.3 Mail-Rohdaten (Consulting, `local-only`)

```powershell
robocopy 'C:\Users\patri\AI-OS\AI-Consulting-OS\local-only\mail-archive' `
         "$Backup\mail-archive" /MIR /R:2 /W:2 /XD '*.tmp' /XF '~$*' `
         /LOG:"$Backup\mail-robocopy.log" /TEE

# Hash-Liste über alle gesicherten Dateien
Get-ChildItem "$Backup\mail-archive" -Recurse -File |
  ForEach-Object { "$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $($_.FullName.Substring($Backup.Length+1))" } |
  Set-Content "$Backup\mail-manifest.sha256"
```

`robocopy /MIR` löscht im Ziel, was in der Quelle fehlt. Das ist für eine 1:1-Sicherung gewollt, aber vor dem ersten Lauf prüfen: Zielpfad muss der Backup-Ordner sein, nie die Quelle.

Vor dem Sichern `mail-index.sqlite3` nicht mit einer laufenden Anwendung öffnen. Der Index ist mitgesichert, weil er Importherkunft und Threads enthält; die EML- und Anhangsbytes sind die unersetzlichen Originale.

### 4.4 Wissensbasis-Store (nach Freigabe)

Die `wb`-Befehle werden aus `shared/tools/wissensbasis` ausgeführt (oder mit `PYTHONPATH` auf dieses Verzeichnis).

```powershell
# Konsistente Sicherung (SQLite-Backup-API, Manifest, Hash-Prüfung)
python -m wb backup --root C:\AI-OS-Wissensbasis --out "$Backup\store\wissensbasis"

# Schreibgeschütztes Austauschpaket (nur eingefroren; nicht in OneDrive öffnen)
python -m wb package create --root C:\AI-OS-Wissensbasis --out "$Backup\store\wissensbasis-package"

# Prüfung der Sicherung
python -m wb verify --root C:\AI-OS-Wissensbasis
```

Die Kopie in OneDrive darf ausschließlich als **Archiv** liegen. Vor Nutzung auf dem zweiten Rechner lokal wiederherstellen:

```powershell
python -m wb restore --from "$Backup\store\wissensbasis-package" --root C:\AI-OS-Wissensbasis-ReadOnly --readonly
```

### 4.5 Verschlüsselung für Offsite

- USB: BitLocker (`manage-bde -on G: -UsedSpaceOnly -EncryptionMethod XtsAes256`) und Passphrase separat verwahren.
- Archiv: `7z a -t7z -mhe=on -mx=9 -p "$Backup\offsite\ai-os-2026-11-05.7z" "$Backup"` (Passphrase interaktiv; nicht in Skripten speichern).
- Keine unverschlüsselten Privatarchive in OneDrive. Keine Passphrase in `config.json`, Repositories oder Logs.

## 5. Rhythmus und Aufbewahrung

| Rhythmus | Umfang |
| --- | --- |
| Täglich (oder nach Arbeitstag) | Git-Bundles, uncommittete Patches, Mail-Archiv inkrementell (`robocopy /MIR`), Wissensbasis-`wb backup` |
| Wöchentlich | vollständiger Satz inkl. unveränderter EML, Bundle-Verifikation, `wb verify` |
| Monatlich | versiegelter Monatssatz (USB ausgelagert oder verschlüsseltes Archiv offsite) |
| Vierteljährlich | Wiederherstellungstest: Bundle klonen, Store wiederherstellen, Suche/Verify prüfen |

Aufbewahrung: 14 tägliche, 8 wöchentliche, 12 monatliche Sätze; Monatssätze erst nach bestandenem Wiederherstellungstest löschen.

## 6. Wiederherstellungstest (verbindlich)

1. `git clone <bundle> <temporär>` und `git -C <temporär> fsck --full`; Dateizahl und letzter Commit müssen passen.
2. Mail-Archiv: stichprobenartig 20 Dateien hashen und mit `mail-manifest.sha256` vergleichen; `mail_import.py ... search` auf einer Kopie ausführen.
3. Wissensbasis: `python -m wb restore --from <backup> --root <temporär>`, `python -m wb verify`, `python -m wb index rebuild`, eine Goldsuche vergleichen.
4. Ergebnis im Backup-Bericht festhalten; erst dann gilt der Satz als gültig.

## 7. Was ausdrücklich nicht getan wird

- Keine Datei wird verschoben oder gelöscht.
- Kein `git add -f` für `local-only` oder Geheimnisse.
- Keine aktive SQLite-Datenbank in OneDrive.
- Keine Sicherung in einem Repository.
- Keine automatische Löschung von Originalen oder Fassungen.
- Keine Ausführung dieses Vorschlags ohne ausdrückliche Freigabe von Ziel und Zeitpunkt.
