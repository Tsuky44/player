# =============================================================================
# Construit le paquet .ipk du lanceur LG webOS (ADR-0076) — équivalent
# PowerShell de scripts/build-webos.sh.
#
# Le paquet ne contient que app\webos\ : la page qui retient l'adresse du
# serveur et ouvre l'app web qu'il sert. L'app elle-même est le bundle de
# scripts\build-web.ps1, embarqué dans le serveur : c'est lui qu'il faut
# reconstruire pour qu'un téléviseur voie un changement de l'app.
#
# Prérequis : les outils webOS (npm install -g @webos-tools/cli), qui
# fournissent ares-package, et ares-install pour l'envoyer au téléviseur.
# =============================================================================

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
$SourceDir = Join-Path $RootDir "app\webos"
$StageDir = Join-Path $RootDir "app\build\webos\stage"
$OutDir = Join-Path $RootDir "app\build\webos"

if (-not (Get-Command ares-package -ErrorAction SilentlyContinue)) {
    throw "ares-package introuvable : npm install -g @webos-tools/cli"
}

# La version du paquet : $env:ONYX_VERSION quand on la donne (celle de la
# Release), sinon celle de pubspec.yaml sans le numéro de build.
$version = $env:ONYX_VERSION
if (-not $version) {
    $pubspec = Get-Content (Join-Path $RootDir "app\pubspec.yaml") -Raw
    if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)') {
        throw "version introuvable dans app\pubspec.yaml"
    }
    $version = $Matches[1]
}
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "version invalide : '$version' (format attendu : X.Y.Z)"
}

Write-Host "1. Préparation du lanceur $version..." -ForegroundColor Yellow
if (Test-Path $StageDir) { Remove-Item $StageDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
Copy-Item -Path (Join-Path $SourceDir "*") -Destination $StageDir -Recurse -Force

$appinfoPath = Join-Path $StageDir "appinfo.json"
$appinfo = Get-Content $appinfoPath -Raw | ConvertFrom-Json
$appinfo.version = $version
# Sans BOM : ares-package lit l'appinfo comme du JSON strict.
[System.IO.File]::WriteAllText($appinfoPath, ($appinfo | ConvertTo-Json),
    (New-Object System.Text.UTF8Encoding $false))

Write-Host "2. Paquet .ipk..." -ForegroundColor Yellow
ares-package $StageDir --outdir $OutDir
if ($LASTEXITCODE -ne 0) { throw "ares-package a échoué" }
Remove-Item $StageDir -Recurse -Force

# Le nom des autres installateurs de la Release (Onyx-<version>-<plateforme>).
$ipk = Join-Path $OutDir "Onyx-$version-webos.ipk"
Move-Item -Force (Join-Path $OutDir "com.tsuky.onyx_${version}_all.ipk") $ipk

Write-Host "Paquet : $ipk. Pour l'installer :" -ForegroundColor Green
Write-Host "  ares-install --device <téléviseur> $ipk"
