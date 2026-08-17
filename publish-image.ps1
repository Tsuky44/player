# =============================================================================
# Usage :
#   .\publish-image.ps1            # récupère les artefacts des autres
#                                  # plateformes depuis l'image :latest
#   .\publish-image.ps1 -NoPull    # n'utilise QUE le contenu actuel de
#                                  # server\downloads\
#
# -NoPull sert quand les artefacts des autres plateformes ont été copiés à la
# main dans server\downloads\ (clé USB, scp...). Sans ce commutateur, le pull de
# l'étape 2 écrase un fichier copié manuellement par celui de l'image
# précédente, puisque les deux portent le même nom.
# =============================================================================
param(
    [switch]$NoPull
)

$GitHubUser = "tsuky44" # Doit être en minuscules pour ghcr.io
$ImageName = "playeur-server"

# TENTATIVE DE CORRECTION AUTOMATIQUE DU PATH DOCKER
if (-not (Get-Command "docker" -ErrorAction SilentlyContinue)) {
    $PossiblePath = "C:\Program Files\Docker\Docker\resources\bin"
    if (Test-Path $PossiblePath) {
        Write-Host "Docker non trouvé dans le PATH, ajout temporaire de : $PossiblePath" -ForegroundColor Yellow
        $env:PATH = "$env:PATH;$PossiblePath"
    }
}

# Le démon, pas seulement le CLI : `docker login` réussit sans lui (le CLI gère
# l'authentification côté client), et sans cette vérification l'échec n'arrive
# qu'à la dernière étape, après le build des apps et du bundle web.
docker info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "ERREUR : le démon Docker n'est pas joignable. Démarrez Docker Desktop, attendez qu'il soit prêt, puis relancez."
    exit 1
}

Write-Host "=== Publication vers GitHub Packages (ghcr.io) ===" -ForegroundColor Cyan
Write-Host "NOTE : Vous devez avoir un Personal Access Token (PAT) avec les droits 'write:packages' et 'delete:packages'."
Write-Host "Créez-en un ici : https://github.com/settings/tokens/new"

function Check-Error {
    param([string]$Message)
    if ($LASTEXITCODE -ne 0) {
        Write-Error "ERREUR : $Message (Code de sortie: $LASTEXITCODE)"
        exit 1
    }
}

# Déterminer le répertoire du script pour utiliser des chemins absolus
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ServerPath = Join-Path $ScriptDir "server"
$DownloadsDir = Join-Path $ServerPath "downloads"

# Définir la version par défaut
$CurrentVersion = "1.0.0"

Write-Host ""
$TargetVersion = Read-Host "Entrez la version à publier (Appuyez sur Entrée pour '$CurrentVersion')"
if ([string]::IsNullOrEmpty($TargetVersion)) {
    $TargetVersion = $CurrentVersion
}

# Nettoyer les préfixes 'v' si l'utilisateur l'a saisi
$TargetVersion = $TargetVersion -replace '^v', ''

# Générer les tags Docker
$VersionTag = "v$TargetVersion"
$MinorVersion = $TargetVersion -replace '\.\d+$', '' # ex: 1.0.0 -> 1.0
$MinorVersionTag = "v$MinorVersion"

Write-Host ""
Write-Host "--- Résumé de la publication ---" -ForegroundColor Cyan
Write-Host "Image cible    : ghcr.io/$GitHubUser/$ImageName" -ForegroundColor Yellow
Write-Host "Version cible  : $TargetVersion" -ForegroundColor Green
Write-Host "Tags Docker    : latest, $VersionTag, $MinorVersionTag" -ForegroundColor Green
Write-Host "--------------------------------" -ForegroundColor Cyan
Write-Host ""

# Login
Write-Host "1. Connexion à ghcr.io..." -ForegroundColor Yellow
Write-Host "Veuillez entrer votre Personal Access Token (PAT) GitHub:"
$Token = Read-Host -AsSecureString
$PlainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token))
echo $PlainToken | docker login ghcr.io -u $GitHubUser --password-stdin
Check-Error "Échec de la connexion à GitHub Packages."

# Les applications installables (APK / DMG / EXE) sont embarquées dans l'image
# et servies sur /api/downloads. Flutter ne cross-compile pas le desktop : cette
# machine Windows produit l'EXE et l'APK, jamais le DMG. Les artefacts des
# autres plateformes sont donc récupérés depuis l'image publiée précédemment,
# qui sert de stockage entre les machines de build.
if ($NoPull) {
    Write-Host "2. Récupération depuis :latest ignorée (-NoPull)." -ForegroundColor Yellow
    Write-Host "   Seul le contenu actuel de server\downloads\ sera embarqué."
    New-Item -ItemType Directory -Force -Path $DownloadsDir | Out-Null
} else {
    Write-Host "2. Récupération des applications déjà publiées..." -ForegroundColor Yellow
    $LatestImage = "ghcr.io/$GitHubUser/${ImageName}:latest"
    docker pull --platform linux/amd64 $LatestImage 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $PrevCid = (docker create --platform linux/amd64 $LatestImage 2>$null)
        if ($PrevCid) {
            New-Item -ItemType Directory -Force -Path $DownloadsDir | Out-Null
            docker cp "${PrevCid}:/app/downloads/." "$DownloadsDir" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "   Artefacts récupérés depuis l'image :latest" -ForegroundColor Green
            } else {
                Write-Host "   (aucun artefact dans l'image précédente)"
            }
            docker rm $PrevCid 2>&1 | Out-Null
        }
    } else {
        Write-Host "   (image :latest introuvable — première publication ?)"
    }
}
# docker pull/create mettent $LASTEXITCODE à une valeur non nulle en cas
# d'absence d'image : on le remet à zéro pour ne pas piéger le Check-Error suivant.
$global:LASTEXITCODE = 0

Write-Host ""
$BuildApps = Read-Host "Builder les applications (EXE/APK sur cette machine) ? [o/N]"
Write-Host ""
if ($BuildApps -match '^[oOyY]$') {
    Write-Host "2b. Build des applications clientes..." -ForegroundColor Yellow
    & (Join-Path $ScriptDir "scripts\build-releases.ps1")
    Check-Error "Échec du build des applications"
    & (Join-Path $ScriptDir "scripts\stage-downloads.ps1")
    Check-Error "Échec du staging des applications"
} else {
    Write-Host "   Build des applications ignoré — l'image conservera les artefacts précédents."
}

# Le bundle Flutter Web est embarqué dans le binaire Go (go:embed), il doit donc
# être construit AVANT le build Docker : le contexte du build est server\, et
# webui.go lit server\webui\dist\ au moment de la compilation.
Write-Host "3. Build du client Web..." -ForegroundColor Yellow
& (Join-Path $ScriptDir "scripts\build-web.ps1")
Check-Error "Échec du build du client Web"

# Build & Push App
Write-Host "4. Build & Push de l'image Go Server (amd64)..." -ForegroundColor Yellow

# Utilisation de buildx avec --platform linux/amd64 pour forcer la
# compilation d'une image amd64, meme depuis un Mac ARM64.
# Le --push publie l'image directement sans stocker l'image locale ARM64.
docker buildx build `
    --platform linux/amd64 `
    --push `
    -t "ghcr.io/$GitHubUser/${ImageName}:latest" `
    -t "ghcr.io/$GitHubUser/${ImageName}:${VersionTag}" `
    -t "ghcr.io/$GitHubUser/${ImageName}:${MinorVersionTag}" `
    "$ServerPath"
Check-Error "Échec du build ou du push de l'application"

Write-Host "=== Terminé ! ===" -ForegroundColor Green
Write-Host "L'image est disponible sur :"
Write-Host "- ghcr.io/$GitHubUser/${ImageName}:latest"
Write-Host "- ghcr.io/$GitHubUser/${ImageName}:${VersionTag}"
Write-Host "- ghcr.io/$GitHubUser/${ImageName}:${MinorVersionTag}"
Write-Host ""
Write-Host "Applications embarquées (visibles dans Paramètres -> Applications) :"
$staged = Get-ChildItem -Path $DownloadsDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in ".apk", ".dmg", ".exe", ".zip" }
if ($staged) {
    foreach ($f in $staged) {
        Write-Host ("- {0} ({1} Mo)" -f $f.Name, [math]::Round($f.Length / 1MB, 1))
    }
} else {
    Write-Host "- aucune (relancez en répondant 'o' au build des applications)"
}
Write-Host ""
