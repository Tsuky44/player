# =============================================================================
# Stage les applications installables dans server\downloads\, d'où le Dockerfile
# les copie et où le serveur Go les publie sur /api/downloads.
#
# Usage :
#   .\scripts\stage-downloads.ps1                 # dist\latest
#   .\scripts\stage-downloads.ps1 -DistDir <dir>
#
# Les fichiers sont renommés Onyx-<version>-<plateforme>.<ext> pour que l'URL de
# téléchargement d'une plateforme reste stable, et l'artefact précédent de cette
# même plateforme est supprimé.
#
# Les plateformes absentes de <DistDir> ne sont pas touchées : c'est ce qui
# permet à une publication Windows de conserver le DMG récupéré depuis l'image
# précédente.
# =============================================================================

param(
    [string]$DistDir
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
$AppDir = Join-Path $RootDir "app"
$DownloadsDir = Join-Path $RootDir "server\downloads"

if (-not $DistDir) {
    $DistDir = Join-Path $RootDir "dist\latest"
}
if (-not (Test-Path $DistDir)) {
    throw "Dossier de build introuvable : $DistDir"
}

$pubspec = Get-Content (Join-Path $AppDir "pubspec.yaml") -Raw
if ($pubspec -match 'version:\s*([^\s+]+)') { $Version = $Matches[1] } else { $Version = "1.0.0" }

New-Item -ItemType Directory -Force -Path $DownloadsDir | Out-Null

# Le plus gros fichier de l'extension : évite les stubs et attrape le vrai
# installeur quand un build laisse plusieurs candidats.
function Find-Artifact {
    param([string]$Extension, [string]$Skip)
    Get-ChildItem -Path $DistDir -Recurse -File -Filter "*.$Extension" -ErrorAction SilentlyContinue |
        Where-Object { -not $Skip -or $_.Name -ne $Skip } |
        Sort-Object Length -Descending |
        Select-Object -First 1
}

function Add-Artifact {
    param([string]$Platform, [string]$Extension, [System.IO.FileInfo]$Source)

    # Supprime l'artefact précédent de cette plateforme, quelle que soit sa version.
    Get-ChildItem -Path $DownloadsDir -File -Filter "*-$Platform.$Extension" -ErrorAction SilentlyContinue |
        Remove-Item -Force

    $dst = Join-Path $DownloadsDir "Onyx-$Version-$Platform.$Extension"
    Copy-Item $Source.FullName $dst -Force
    $mb = [math]::Round((Get-Item $dst).Length / 1MB, 1)
    Write-Host ("    OK {0,-16} -> {1} ({2} Mo)" -f $Platform, (Split-Path $dst -Leaf), $mb)
}

Write-Host "Staging des applications depuis $DistDir..." -ForegroundColor Yellow

$staged = 0

$apk = Find-Artifact -Extension "apk" -Skip "app-release.apk"
if ($apk) { Add-Artifact -Platform "android" -Extension "apk" -Source $apk; $staged++ }

$dmg = Find-Artifact -Extension "dmg"
if ($dmg) { Add-Artifact -Platform "macos" -Extension "dmg" -Source $dmg; $staged++ }

$exe = Find-Artifact -Extension "exe"
if ($exe) { Add-Artifact -Platform "windows" -Extension "exe" -Source $exe; $staged++ }

$zip = Find-Artifact -Extension "zip"
if ($zip) { Add-Artifact -Platform "windows-portable" -Extension "zip" -Source $zip; $staged++ }

if ($staged -eq 0) {
    throw "Aucun artefact trouvé dans $DistDir"
}

Write-Host "=== server\downloads\ ===" -ForegroundColor Green
Get-ChildItem -Path $DownloadsDir -File |
    Where-Object { $_.Name -ne ".gitkeep" } |
    Select-Object Name, @{Name = "Mo"; Expression = { [math]::Round($_.Length / 1MB, 1) } }
