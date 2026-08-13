# =============================================================================
# Playeur — build Windows EXE (+ APK optionnel) puis copie dans dist/
# =============================================================================
# Usage (PowerShell, depuis la racine du repo ou app/) :
#   .\scripts\build-releases.ps1
#   .\scripts\build-releases.ps1 -Android
#   .\scripts\build-releases.ps1 -WindowsOnly
# =============================================================================

param(
    [switch]$Android,
    [switch]$WindowsOnly,
    [switch]$SkipInstaller
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $RootDir "app\pubspec.yaml"))) {
    # Script may live next to app/ when copied
    if (Test-Path (Join-Path $PSScriptRoot "..\app\pubspec.yaml")) {
        $RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
    }
}

$AppDir = Join-Path $RootDir "app"
$DistRoot = Join-Path $RootDir "dist"

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw "flutter introuvable dans le PATH"
}

$pubspec = Get-Content (Join-Path $AppDir "pubspec.yaml") -Raw
if ($pubspec -match 'version:\s*([^\s+]+)') {
    $Version = $Matches[1]
} else {
    $Version = "1.0.0"
}

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$OutDir = Join-Path $DistRoot "Playeur-$Version-$Stamp"
$AndroidOut = Join-Path $OutDir "android"
$WindowsOut = Join-Path $OutDir "windows"
$Manifest = Join-Path $OutDir "MANIFEST.txt"

New-Item -ItemType Directory -Force -Path $AndroidOut, $WindowsOut | Out-Null

@"
Playeur release build (PowerShell)
version: $Version
stamp: $Stamp
host: windows
started: $(Get-Date -Format o)
"@ | Set-Content -Path $Manifest -Encoding UTF8

Push-Location $AppDir
try {
    $env:CMAKE_GENERATOR = "Ninja"
    Write-Host "==> flutter pub get"
    flutter pub get

    $doWindows = -not $Android.IsPresent -or $WindowsOnly.IsPresent -or (-not $Android.IsPresent)
    if ($WindowsOnly) { $doWindows = $true }
    if (-not $Android -and -not $WindowsOnly) {
        $doWindows = $true
        $doAndroid = $true
    } else {
        $doAndroid = [bool]$Android
        if ($WindowsOnly) { $doAndroid = $false }
    }

    if ($doWindows) {
        Write-Host "==> flutter build windows --release"
        flutter build windows --release

        $release = Join-Path $AppDir "build\windows\x64\runner\Release"
        if (-not (Test-Path $release)) {
            throw "Dossier Release introuvable: $release"
        }

        $zipPath = Join-Path $WindowsOut "Playeur-$Version-windows-x64.zip"
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Compress-Archive -Path (Join-Path $release "*") -DestinationPath $zipPath -Force
        Write-Host "    ✓ ZIP → $zipPath"
        Add-Content $Manifest "windows_zip: $zipPath"

        if (-not $SkipInstaller) {
            $iscc = Get-Command iscc -ErrorAction SilentlyContinue
            if (-not $iscc) {
                $iscc = Get-Command "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" -ErrorAction SilentlyContinue
            }
            $iss = Join-Path $AppDir "installer.iss"
            if ($iscc -and (Test-Path $iss)) {
                Write-Host "==> Inno Setup"
                & $iscc.Source $iss
                $setupSrc = Join-Path $AppDir "Output\ProjectPlayer-Setup.exe"
                if (Test-Path $setupSrc) {
                    $setupDst = Join-Path $WindowsOut "Playeur-$Version-Setup.exe"
                    Copy-Item $setupSrc $setupDst -Force
                    Write-Host "    ✓ EXE → $setupDst"
                    Add-Content $Manifest "windows_exe: $setupDst"
                }
            } else {
                Write-Host "    ! Inno Setup absent — ZIP uniquement"
            }
        }
    } else {
        Add-Content $Manifest "windows: skipped"
    }

    if ($doAndroid) {
        Write-Host "==> flutter build apk --release"
        flutter build apk --release
        $apkSrc = Join-Path $AppDir "build\app\outputs\flutter-apk\app-release.apk"
        if (Test-Path $apkSrc) {
            $apkDst = Join-Path $AndroidOut "Playeur-$Version.apk"
            Copy-Item $apkSrc $apkDst -Force
            Copy-Item $apkSrc (Join-Path $AndroidOut "app-release.apk") -Force
            Write-Host "    ✓ APK → $apkDst"
            Add-Content $Manifest "android: $apkDst"
        } else {
            throw "APK introuvable"
        }
    } else {
        Add-Content $Manifest "android: skipped"
    }
}
finally {
    Pop-Location
}

Add-Content $Manifest "finished: $(Get-Date -Format o)"
Add-Content $Manifest "output_dir: $OutDir"

$latest = Join-Path $DistRoot "latest"
if (Test-Path $latest) { Remove-Item $latest -Force -Recurse -ErrorAction SilentlyContinue }
cmd /c mklink /J "$latest" "$OutDir" | Out-Null

Write-Host ""
Write-Host "Dossier: $OutDir"
Get-ChildItem -Recurse $OutDir | Select-Object FullName
