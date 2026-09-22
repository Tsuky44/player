# Rend brand/installer-background.svg en PNG pour chaque échelle d'affichage
# Windows, dans app/windows/installer/. Inno Setup choisit lui-même l'image la
# plus proche de la taille réelle de la fenêtre : sans les grandes tailles, le
# fond serait étiré et flou à 150 % ou 200 %.
#
# Usage (Windows, Edge installé) :  .\brand\generate-installer-art.ps1

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Svg = Join-Path $PSScriptRoot "installer-background.svg"
$OutDir = Join-Path $Root "app\windows\installer"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$edge = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw "Microsoft Edge introuvable" }

$work = Join-Path ([IO.Path]::GetTempPath()) "onyx-installer-art"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$html = Join-Path $work "page.html"
$svgUri = ([Uri]$Svg).AbsoluteUri
@"
<!doctype html><html><body style="margin:0;background:#121414;overflow:hidden">
<img src="$svgUri" width="600" height="432" style="display:block">
</body></html>
"@ | Set-Content -Path $html -Encoding UTF8

# Doivent rester alignées sur WizardBackImageFile dans app/installer.iss.
foreach ($pct in 100, 125, 150, 175, 200, 250) {
    $out = Join-Path $OutDir "background-$pct.png"
    if (Test-Path $out) { Remove-Item $out -Force }
    # Profil jetable : un Edge déjà ouvert ne doit pas intercepter le rendu.
    # Edge écrit sa progression sur stderr, que PowerShell 5.1 transforme en
    # erreur fatale sous ErrorActionPreference=Stop.
    $ErrorActionPreference = "Continue"
    & $edge --headless=new --disable-gpu --hide-scrollbars `
        "--user-data-dir=$work\profile" `
        "--force-device-scale-factor=$($pct / 100)" `
        --window-size=600,432 "--screenshot=$out" ([Uri]$html).AbsoluteUri 2>&1 | Out-Null
    $ErrorActionPreference = "Stop"
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Test-Path $out) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    if (-not (Test-Path $out)) { throw "Rendu échoué pour $pct %" }
    Write-Host "  $out"
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
