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
                # L'installeur d'Inno Setup laisse choisir le dossier cible, et
                # une machine de build peut très bien l'avoir sous C:\InnoSetup.
                # Le registre est la seule source fiable ; la liste de chemins
                # ne sert que de repli si la désinstallation a laissé le disque
                # propre mais le registre incomplet.
                $candidates = @(
                    (@("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                       "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
                       "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*") |
                        ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } |
                        Where-Object { $_.DisplayName -like "*Inno Setup*" -and $_.InstallLocation } |
                        ForEach-Object { Join-Path $_.InstallLocation "ISCC.exe" })
                    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
                    "C:\Program Files\Inno Setup 6\ISCC.exe"
                    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
                )
                foreach ($c in $candidates) {
                    if ($c -and (Test-Path $c)) { $iscc = Get-Command $c; break }
                }
            }
            $iss = Join-Path $AppDir "installer.iss"
            if ($iscc -and (Test-Path $iss)) {
                Write-Host "==> Inno Setup ($($iscc.Source))"
                # OutputDir est vidé d'abord : sinon un installeur d'un build
                # précédent serait ramassé et publié comme s'il était neuf.
                $OutputDir = Join-Path $AppDir "Output"
                if (Test-Path $OutputDir) { Remove-Item "$OutputDir\*.exe" -Force -ErrorAction SilentlyContinue }

                & $iscc.Source $iss
                if ($LASTEXITCODE -ne 0) { throw "Inno Setup a échoué (code $LASTEXITCODE)" }

                # Le nom vient de OutputBaseFilename dans installer.iss ; on le
                # lit plutôt que de le coder en dur, un nom figé ici ayant déjà
                # fait passer l'installeur à la trappe en silence.
                $setupSrc = Get-ChildItem -Path $OutputDir -File -Filter "*.exe" -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if (-not $setupSrc) {
                    throw "Inno Setup n'a produit aucun .exe dans $OutputDir"
                }
                $setupDst = Join-Path $WindowsOut "Playeur-$Version-Setup.exe"
                Copy-Item $setupSrc.FullName $setupDst -Force
                Write-Host "    ✓ Installeur → $setupDst"
                Add-Content $Manifest "windows_exe: $setupDst"
            } elseif (-not $iscc) {
                # Un avertissement suffisait tant que le ZIP portable faisait
                # l'affaire ; il masquait surtout l'absence d'installeur jusqu'à
                # la publication de l'image.
                throw @"
Inno Setup introuvable — impossible de produire l'installeur .exe.
Installez-le puis relancez :  winget install -e --id JRSoftware.InnoSetup
Ou relancez avec -SkipInstaller pour ne produire que le ZIP portable.
"@
            } else {
                throw "installer.iss introuvable : $iss"
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
