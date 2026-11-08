# NSIS für den Windows-Installer vorab bereitlegen.
#
# Warum es das gibt (08.11.2026, v0.1.339): Der Tauri-Bundler lädt NSIS und
# sein Plugin `nsis_tauri_utils.dll` beim Bündeln selbst, über die Adressen
# `github.com/tauri-apps/…/releases/download/…`. Genau diese Adressen
# antworteten an dem Tag `504` — zwei Läufe hintereinander, von hier aus
# ebenso, während die eigenen Release-Dateien `200` lieferten und die
# Statusseite nichts meldete. Kompiliert war alles, nur der Installer fehlte,
# und mit ihm Windows in `latest.json`.
#
# Was der Schritt tut: dieselben zwei Dateien über andere Wege holen und dorthin
# legen, wo der Bundler zuerst nachsieht (`%LOCALAPPDATA%\tauri\NSIS`). Findet
# er dort alle Pflichtdateien und den richtigen Hash des Plugins, lädt er nichts.
#
# Drei Regeln, die das tragen:
# - **Adressen und Prüfsummen kommen aus der installierten Tauri-CLI**, nicht
#   aus diesem Skript. Beide stehen als Klartext im Binärteil. So kann ein
#   CLI-Update, das eine neue NSIS-Fassung verlangt, nicht still eine alte
#   unterschieben: die neue Adresse wird gelesen, und eine Datei zählt nur, wenn
#   ihr SHA-1 im Binärteil steht.
# - **Wege der Reihe nach**: die GitHub-API (`releases/assets/{id}`, ein anderer
#   Downloadweg — an jenem Tag lieferte sie, die Download-Adresse nicht), dann
#   die Download-Adresse selbst, für NSIS zuletzt SourceForge (dort liegt
#   dieselbe Datei byte-gleich, SHA-1 gegengeprüft).
# - **Scheitert alles, scheitert der Schritt nicht.** Er sagt es als Warnung,
#   und der Bundler versucht es selbst — wie vor diesem Schritt. Ein
#   Vorbereitungsschritt, der den Build öfter bricht als das Problem, das er
#   umgeht, wäre schlechter als keiner.

param(
  [string]$CliPfad = '',
  [string]$ToolsPfad = (Join-Path $env:LOCALAPPDATA 'tauri')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Invoke-WebRequest ist mit Fortschrittsanzeige um ein Vielfaches langsamer

function Warnung([string]$text) { Write-Host "::warning::NSIS vorab: $text — der Bundler lädt selbst." }

if (-not $CliPfad) {
  $cli = Get-ChildItem 'node_modules/@tauri-apps/cli-win32-*/*.node' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cli) { Warnung 'Tauri-CLI nicht gefunden'; exit 0 }
  $CliPfad = $cli.FullName
}
$binaer = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($CliPfad))

$nsisUrl = [regex]::Match($binaer, 'https://github\.com/tauri-apps/binary-releases/releases/download/nsis-[0-9.]+/nsis-([0-9.]+)\.zip')
$utilsUrl = [regex]::Match($binaer, 'https://github\.com/tauri-apps/nsis-tauri-utils/releases/download/nsis_tauri_utils-v[0-9.]+/nsis_tauri_utils\.dll')
if (-not $nsisUrl.Success -or -not $utilsUrl.Success) { Warnung "Download-Adressen nicht in $CliPfad gefunden"; exit 0 }
$fassung = $nsisUrl.Groups[1].Value
Write-Host "Tauri-CLI erwartet NSIS $fassung und $($utilsUrl.Value)"

$nsisDir = Join-Path $ToolsPfad 'NSIS'
if (Test-Path $nsisDir) { Write-Host "$nsisDir ist schon da — nichts zu tun."; exit 0 }

$arbeit = Join-Path ([System.IO.Path]::GetTempPath()) ("nsis-vorab-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $arbeit | Out-Null

# Eine Datei über die Wege der Reihe nach holen; zurück kommt der Pfad einer
# Datei, deren SHA-1 im CLI-Binärteil steht — oder $null.
function Hole([string]$url, [string[]]$weitere) {
  $name = Split-Path $url -Leaf
  $ziel = Join-Path $arbeit $name
  $wege = @()
  if ($url -match '^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)$') {
    $wege += [pscustomobject]@{ art = 'api'; owner = $Matches[1]; repo = $Matches[2]; tag = $Matches[3]; name = $Matches[4] }
  }
  $wege += [pscustomobject]@{ art = 'url'; url = $url }
  foreach ($w in $weitere) { $wege += [pscustomobject]@{ art = 'url'; url = $w } }

  foreach ($weg in $wege) {
    for ($versuch = 1; $versuch -le 2; $versuch++) {
      try {
        if ($weg.art -eq 'api') {
          $kopf = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'mediaflow-release' }
          if ($env:GH_TOKEN) { $kopf.Authorization = "Bearer $env:GH_TOKEN" }
          $rel = Invoke-RestMethod -Headers $kopf "https://api.github.com/repos/$($weg.owner)/$($weg.repo)/releases/tags/$($weg.tag)"
          $asset = $rel.assets | Where-Object { $_.name -eq $weg.name } | Select-Object -First 1
          if (-not $asset) { throw "kein Asset $($weg.name) im Release $($weg.tag)" }
          $kopf.Accept = 'application/octet-stream'
          Invoke-WebRequest -Headers $kopf -OutFile $ziel "https://api.github.com/repos/$($weg.owner)/$($weg.repo)/releases/assets/$($asset.id)"
          $quelle = "GitHub-API (Asset $($asset.id))"
        } else {
          Invoke-WebRequest -Headers @{ 'User-Agent' = 'mediaflow-release' } -OutFile $ziel $weg.url
          $quelle = $weg.url
        }
        $sha = (Get-FileHash -Algorithm SHA1 $ziel).Hash.ToUpperInvariant()
        if ($binaer.Contains($sha)) {
          Write-Host "  $name über $quelle — SHA-1 $sha passt zur Tauri-CLI"
          return $ziel
        }
        Write-Host "  $name über $quelle — SHA-1 $sha steht nicht in der Tauri-CLI, verworfen"
        Remove-Item $ziel -Force
        break # derselbe Weg liefert beim zweiten Mal dieselben falschen Bytes
      } catch {
        $wo = if ($weg.art -eq 'api') { 'GitHub-API' } else { $weg.url }
        Write-Host "  $name über $wo, Versuch $versuch — $($_.Exception.Message)"
        if ($versuch -lt 2) { Start-Sleep -Seconds 10 }
      }
    }
  }
  return $null
}

$zip = Hole $nsisUrl.Value @("https://downloads.sourceforge.net/project/nsis/NSIS%203/$fassung/nsis-$fassung.zip")
$dll = Hole $utilsUrl.Value @()
if (-not $zip) { Warnung "nsis-$fassung.zip auf keinem Weg zu bekommen"; exit 0 }
if (-not $dll) { Warnung 'nsis_tauri_utils.dll auf keinem Weg zu bekommen'; exit 0 }

New-Item -ItemType Directory -Force $ToolsPfad | Out-Null
$entpackt = Join-Path $arbeit 'x'
Expand-Archive -Path $zip -DestinationPath $entpackt -Force
Move-Item (Join-Path $entpackt "nsis-$fassung") $nsisDir
$plugin = Join-Path $nsisDir 'Plugins/x86-unicode/additional'
New-Item -ItemType Directory -Force $plugin | Out-Null
Copy-Item $dll (Join-Path $plugin 'nsis_tauri_utils.dll')

# Dieselbe Liste wie NSIS_REQUIRED_FILES im Bundler: fehlt eine, löscht er den
# Ordner und lädt neu — dann ist dieser Schritt wirkungslos, und das soll man sehen.
$pflicht = @(
  'makensis.exe', 'Bin/makensis.exe', 'Stubs/lzma-x86-unicode', 'Stubs/lzma_solid-x86-unicode',
  'Plugins/x86-unicode/additional/nsis_tauri_utils.dll', 'Include/MUI2.nsh', 'Include/FileFunc.nsh',
  'Include/x64.nsh', 'Include/nsDialogs.nsh', 'Include/WinMessages.nsh', 'Include/Win/COM.nsh',
  'Include/Win/Propkey.nsh', 'Include/Win/RestartManager.nsh'
)
$fehlt = $pflicht | Where-Object { -not (Test-Path (Join-Path $nsisDir $_)) }
if ($fehlt) {
  Remove-Item $nsisDir -Recurse -Force
  Warnung "nach dem Entpacken fehlen $($fehlt -join ', ')"
  exit 0
}
Write-Host "NSIS $fassung liegt in $nsisDir — der Bundler lädt nichts."
