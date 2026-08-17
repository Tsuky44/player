#!/bin/bash

# Usage :
#   ./publish-image.sh              # récupère les artefacts des autres
#                                   # plateformes depuis l'image :latest
#   ./publish-image.sh --no-pull    # n'utilise QUE le contenu actuel de
#                                   # server/downloads/
#
# --no-pull sert quand les artefacts des autres plateformes ont été copiés à la
# main dans server/downloads/ (clé USB, scp...). Sans cette option, le pull de
# l'étape 2 écrase un fichier copié manuellement par celui de l'image
# précédente, puisque les deux portent le même nom.

# Configuration
GITHUB_USER="tsuky44" # Doit être en minuscules pour ghcr.io
IMAGE_NAME="playeur-server"
DEFAULT_VERSION="1.0.0"

NO_PULL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-pull) NO_PULL=1; shift ;;
        -h|--help) sed -n '3,13p' "$0"; exit 0 ;;
        *) echo "Option inconnue : $1" >&2; exit 1 ;;
    esac
done

# Couleurs pour le terminal
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # Pas de couleur

echo -e "${CYAN}=== Publication vers GitHub Packages (ghcr.io) ===${NC}"
echo "NOTE : Vous devez avoir un Personal Access Token (PAT) avec les droits 'write:packages' et 'delete:packages'."
echo "Créez-en un ici : https://github.com/settings/tokens/new"
echo ""

# Vérifier si docker est installé
if ! command -v docker &> /dev/null; then
    echo -e "${RED}ERREUR : Docker n'est pas installé ou n'est pas dans le PATH.${NC}"
    exit 1
fi

# Le demon, pas seulement le CLI : `docker login` reussit sans lui (le CLI gere
# l'authentification cote client), et sans cette verification l'echec n'arrive
# qu'a la derniere etape, apres le build des apps et du bundle web.
if ! docker info &> /dev/null; then
    echo -e "${RED}ERREUR : le démon Docker n'est pas joignable.${NC}"
    echo "Démarrez Docker Desktop, attendez qu'il soit prêt, puis relancez :"
    echo "  open -a Docker"
    exit 1
fi

# Répertoire du script et chemin du serveur
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
SERVER_PATH="$SCRIPT_DIR/server"
DOWNLOADS_DIR="$SERVER_PATH/downloads"

# Demander la version à publier
read -p "Entrez la version à publier (Appuyez sur Entrée pour '$DEFAULT_VERSION') : " TARGET_VERSION
if [ -z "$TARGET_VERSION" ]; then
    TARGET_VERSION="$DEFAULT_VERSION"
fi

# Nettoyer les préfixes 'v' si l'utilisateur l'a saisi
TARGET_VERSION="${TARGET_VERSION#v}"

# Générer les tags
VERSION_TAG="v$TARGET_VERSION"
# Extraire la version mineure (ex: 1.0.0 -> 1.0)
MINOR_VERSION=$(echo "$TARGET_VERSION" | cut -d. -f1,2)
MINOR_VERSION_TAG="v$MINOR_VERSION"

echo ""
echo -e "${CYAN}--- Résumé de la publication ---${NC}"
echo -e "Image cible    : ${YELLOW}ghcr.io/$GITHUB_USER/$IMAGE_NAME${NC}"
echo -e "Version cible  : ${GREEN}$TARGET_VERSION${NC}"
echo -e "Tags Docker    : ${GREEN}latest, $VERSION_TAG, $MINOR_VERSION_TAG${NC}"
echo -e "${CYAN}--------------------------------${NC}"
echo ""

# Connexion à ghcr.io
echo -e "${YELLOW}1. Connexion à ghcr.io...${NC}"
echo "Veuillez entrer votre Personal Access Token (PAT) GitHub :"
# Masquer la saisie du Token
read -s TOKEN
echo ""

if [ -z "$TOKEN" ]; then
    echo -e "${RED}ERREUR : Le Token ne peut pas être vide.${NC}"
    exit 1
fi

echo "$TOKEN" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin
if [ $? -ne 0 ]; then
    echo -e "${RED}ERREUR : Échec de la connexion à GitHub Packages.${NC}"
    exit 1
fi

# Les applications installables (APK / DMG / EXE) sont embarquees dans l'image
# et servies sur /api/downloads. Flutter ne cross-compile pas le desktop : ce
# Mac produit l'APK et le DMG, jamais l'EXE Windows. Les artefacts des autres
# plateformes sont donc recuperes depuis l'image publiee precedemment, qui sert
# de stockage entre les machines de build.
if [ "$NO_PULL" -eq 1 ]; then
    echo -e "${YELLOW}2. Récupération depuis :latest ignorée (--no-pull).${NC}"
    echo "   Seul le contenu actuel de server/downloads/ sera embarqué."
    mkdir -p "$DOWNLOADS_DIR"
elif docker pull --platform linux/amd64 "ghcr.io/$GITHUB_USER/$IMAGE_NAME:latest" >/dev/null 2>&1; then
    echo -e "${YELLOW}2. Récupération des applications déjà publiées...${NC}"
    PREV_CID=$(docker create --platform linux/amd64 "ghcr.io/$GITHUB_USER/$IMAGE_NAME:latest" 2>/dev/null)
    if [ -n "$PREV_CID" ]; then
        mkdir -p "$DOWNLOADS_DIR"
        docker cp "$PREV_CID:/app/downloads/." "$DOWNLOADS_DIR/" >/dev/null 2>&1 \
            && echo -e "${GREEN}   Artefacts récupérés depuis l'image :latest${NC}" \
            || echo "   (aucun artefact dans l'image précédente)"
        docker rm "$PREV_CID" >/dev/null 2>&1
    fi
else
    echo -e "${YELLOW}2. Récupération des applications déjà publiées...${NC}"
    echo "   (image :latest introuvable — première publication ?)"
fi

echo ""
read -p "Builder les applications (APK/DMG sur ce Mac) ? [o/N] : " BUILD_APPS
echo ""
if [[ "$BUILD_APPS" =~ ^[oOyY]$ ]]; then
    echo -e "${YELLOW}2b. Build des applications clientes...${NC}"
    # Mode auto : APK + DMG sur macOS, APK + EXE sur Windows. Le code de sortie
    # 2 signale qu'une cible a echoue alors que d'autres ont reussi — on
    # continue avec ce qui a ete produit.
    "$SCRIPT_DIR/scripts/build-releases.sh"
    BUILD_STATUS=$?
    if [ "$BUILD_STATUS" -ne 0 ] && [ "$BUILD_STATUS" -ne 2 ]; then
        echo -e "${RED}ERREUR : Échec du build des applications.${NC}"
        exit 1
    fi
    "$SCRIPT_DIR/scripts/stage-downloads.sh"
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERREUR : Échec du staging des applications.${NC}"
        exit 1
    fi
else
    echo "   Build des applications ignoré — l'image conservera les artefacts précédents."
fi

# Le bundle Flutter Web est embarque dans le binaire Go (go:embed), il doit donc
# etre construit AVANT le build Docker : le contexte du build est server/, et
# webui.go lit server/webui/dist/ au moment de la compilation.
echo -e "${YELLOW}3. Build du client Web...${NC}"
"$SCRIPT_DIR/scripts/build-web.sh"
if [ $? -ne 0 ]; then
    echo -e "${RED}ERREUR : Échec du build du client Web.${NC}"
    exit 1
fi

# Build & Push
echo -e "${YELLOW}4. Build & Push de l'image Go Server (amd64)...${NC}"

# Utilisation de buildx avec --platform linux/amd64 pour forcer la
# compilation d'une image amd64, meme depuis un Mac ARM64.
# Le --push publie l'image directement sans stocker l'image locale ARM64.
docker buildx build \
    --platform linux/amd64 \
    --push \
    -t "ghcr.io/$GITHUB_USER/$IMAGE_NAME:latest" \
    -t "ghcr.io/$GITHUB_USER/$IMAGE_NAME:$VERSION_TAG" \
    -t "ghcr.io/$GITHUB_USER/$IMAGE_NAME:$MINOR_VERSION_TAG" \
    "$SERVER_PATH"

if [ $? -ne 0 ]; then
    echo -e "${RED}ERREUR : Échec du build ou du push de l'application.${NC}"
    exit 1
fi


echo ""
echo -e "${GREEN}=== Terminé ! ===${NC}"
echo "L'image est disponible sur :"
echo "- ghcr.io/$GITHUB_USER/$IMAGE_NAME:latest"
echo "- ghcr.io/$GITHUB_USER/$IMAGE_NAME:$VERSION_TAG"
echo "- ghcr.io/$GITHUB_USER/$IMAGE_NAME:$MINOR_VERSION_TAG"
echo ""
echo "Applications embarquées (visibles dans Paramètres → Applications) :"
if ls "$DOWNLOADS_DIR"/*.{apk,dmg,exe,zip} >/dev/null 2>&1; then
    for f in "$DOWNLOADS_DIR"/*.apk "$DOWNLOADS_DIR"/*.dmg "$DOWNLOADS_DIR"/*.exe "$DOWNLOADS_DIR"/*.zip; do
        [ -f "$f" ] && echo "- $(basename "$f") ($(du -h "$f" | cut -f1))"
    done
else
    echo "- aucune (relancez en répondant 'o' au build des applications)"
fi
echo ""
