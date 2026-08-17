# =============================================================================
# Construit le bundle Flutter Web et le prépare pour l'embarquement dans le
# binaire Go — équivalent PowerShell de scripts/build-web.sh.
#
# La sortie atterrit dans server\webui\dist\, que webui.go embarque via
# go:embed. À lancer avant `go build` ou avant publish-image.ps1, qui l'appelle
# automatiquement.
# =============================================================================

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
$AppDir = Join-Path $RootDir "app"
$DistDir = Join-Path $RootDir "server\webui\dist"

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw "flutter introuvable dans le PATH"
}

Write-Host "1. Build du bundle Flutter Web..." -ForegroundColor Yellow
# --no-web-resources-cdn est obligatoire ici : par défaut Flutter va chercher
# CanvasKit (son moteur de rendu) sur https://www.gstatic.com. Un serveur média
# auto-hébergé doit s'afficher même quand le réseau du spectateur bloque Google,
# et sans signaler chaque visiteur à un tiers.
Push-Location $AppDir
try {
    flutter build web --release --no-web-resources-cdn
    if ($LASTEXITCODE -ne 0) { throw "flutter build web a échoué" }
}
finally {
    Pop-Location
}

Write-Host "2. Copie vers server\webui\dist\..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
# On vide tout sauf le placeholder, pour que les fichiers supprimés par une
# montée de version Flutter ne restent pas dans le binaire pour toujours.
Get-ChildItem -Path $DistDir -Force |
    Where-Object { $_.Name -ne ".gitkeep" } |
    Remove-Item -Recurse -Force
Copy-Item -Path (Join-Path $AppDir "build\web\*") -Destination $DistDir -Recurse -Force

Write-Host "3. Nettoyage des artefacts inutilisés..." -ForegroundColor Yellow
# Les .symbols sont des tables de symboles pour le debugger : jamais demandées
# par un navigateur, plusieurs Mo chacune, et elles finiraient dans le binaire.
Get-ChildItem -Path $DistDir -Recurse -File -Filter "*.symbols" | Remove-Item -Force

# skwasm / wimp ne sont chargés que par un build WasmGC, impossible ici
# (flutter_secure_storage_web dépend de dart:html). ~17 Mo qu'aucun navigateur
# ne demandera jamais. Idem pour experimental_webparagraph.
$canvasKit = Join-Path $DistDir "canvaskit"
if (Test-Path $canvasKit) {
    Get-ChildItem -Path $canvasKit -Recurse -File |
        Where-Object { $_.Name -like "skwasm*" -or $_.Name -like "wimp*" } |
        Remove-Item -Force
    $webParagraph = Join-Path $canvasKit "experimental_webparagraph"
    if (Test-Path $webParagraph) { Remove-Item $webParagraph -Recurse -Force }
}

Write-Host "4. Pré-compression gzip des assets texte..." -ForegroundColor Yellow
# Pré-compresser au build veut dire que le serveur n'y dépense aucun CPU. On
# garde l'original : les clients qui n'envoient pas Accept-Encoding en ont
# encore besoin.
$compressible = @(".js", ".json", ".html", ".css", ".wasm")
Get-ChildItem -Path $DistDir -Recurse -File |
    Where-Object { $compressible -contains $_.Extension -and $_.Length -gt 1KB } |
    ForEach-Object {
        $source = [System.IO.File]::OpenRead($_.FullName)
        try {
            $target = [System.IO.File]::Create("$($_.FullName).gz")
            try {
                $gzip = [System.IO.Compression.GZipStream]::new(
                    $target, [System.IO.Compression.CompressionLevel]::Optimal)
                try { $source.CopyTo($gzip) } finally { $gzip.Dispose() }
            }
            finally { $target.Dispose() }
        }
        finally { $source.Dispose() }
    }

$size = [math]::Round(
    ((Get-ChildItem -Path $DistDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host "=== Bundle web prêt ($size Mo) dans server\webui\dist\ ===" -ForegroundColor Green
