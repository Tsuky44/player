# Script de lancement Flutter Windows avec le bon generateur CMake pour Visual Studio 2026
# Utilisation: .\run-windows.ps1

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Lancement Flutter (Windows Desktop)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Forcer le generateur CMake pour Ninja (ne depend pas de Visual Studio)
$env:CMAKE_GENERATOR = "Ninja"
Write-Host "[INFO] CMAKE_GENERATOR force a : $env:CMAKE_GENERATOR" -ForegroundColor Green

# Nettoyer le cache CMake specifique a Windows si present
$buildWindowsDir = Join-Path $PSScriptRoot "build\windows"
if (Test-Path $buildWindowsDir) {
    Write-Host "[INFO] Nettoyage du cache build/windows..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force $buildWindowsDir -ErrorAction SilentlyContinue
    Write-Host "[OK] Cache nettoye." -ForegroundColor Green
}

# Nettoyer aussi le cache .dart_tool si probleme persistant
$dartToolDir = Join-Path $PSScriptRoot ".dart_tool"
if (Test-Path $dartToolDir) {
    $windowsBuildDir = Join-Path $dartToolDir "build"
    if (Test-Path $windowsBuildDir) {
        Write-Host "[INFO] Nettoyage du cache .dart_tool/build..." -ForegroundColor Yellow
        Remove-Item -Recurse -Force $windowsBuildDir -ErrorAction SilentlyContinue
        Write-Host "[OK] Cache nettoye." -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "[INFO] Lancement de flutter run -d windows ..." -ForegroundColor Cyan
Write-Host ""

# Lancer Flutter avec le device Windows
& "C:\src\flutter\bin\flutter.bat" run -d windows

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "[ERREUR] Le build a echoue (code: $LASTEXITCODE)." -ForegroundColor Red
    Write-Host "Si l'erreur persiste, essayez de redemarrer votre PC pour que Visual Studio 2026 soit pleinement detecte." -ForegroundColor Red
    exit $LASTEXITCODE
}
