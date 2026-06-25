#!/bin/bash

# Configuration
GITHUB_USER="tsuky44" # Doit être en minuscules pour ghcr.io
IMAGE_NAME="playeur-server"
DEFAULT_VERSION="1.0.0"

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

# Répertoire du script et chemin du serveur
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
SERVER_PATH="$SCRIPT_DIR/server"

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

# Build & Push
echo -e "${YELLOW}2. Build & Push de l'image Go Server (amd64)...${NC}"

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
