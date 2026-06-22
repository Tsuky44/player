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

# Build & Push App
Write-Host "2. Build & Tag de l'image Go Server..." -ForegroundColor Yellow
docker build -t "ghcr.io/$GitHubUser/${ImageName}:latest" -t "ghcr.io/$GitHubUser/${ImageName}:${VersionTag}" -t "ghcr.io/$GitHubUser/${ImageName}:${MinorVersionTag}" "$ServerPath"
Check-Error "Échec du build de l'application"

Write-Host "3. Push des images vers ghcr.io..." -ForegroundColor Yellow
docker push "ghcr.io/$GitHubUser/${ImageName}:latest"
Check-Error "Échec du push (latest)"

docker push "ghcr.io/$GitHubUser/${ImageName}:${VersionTag}"
Check-Error "Échec du push ($VersionTag)"

docker push "ghcr.io/$GitHubUser/${ImageName}:${MinorVersionTag}"
Check-Error "Échec du push ($MinorVersionTag)"

Write-Host "=== Terminé ! ===" -ForegroundColor Green
Write-Host "L'image est disponible sur :"
Write-Host "- ghcr.io/$GitHubUser/${ImageName}:latest"
Write-Host "- ghcr.io/$GitHubUser/${ImageName}:${VersionTag}"
Write-Host "- ghcr.io/$GitHubUser/${ImageName}:${MinorVersionTag}"
Write-Host ""
