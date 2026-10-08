#!/bin/sh
# Point d'entrée de l'image.
#
# Sans réglage, le serveur tourne comme avant, sous root : les installations en
# place ont un dossier ./data créé par root, et un serveur soudain incapable d'y
# écrire ne démarrerait plus après une simple mise à jour.
#
# Avec PUID (et PGID, qui vaut PUID par défaut), le dossier des données est
# rendu à ce compte et le serveur tourne sous lui, sans privilèges : un défaut
# dans le serveur ou dans FFmpeg ne donne alors plus la main sur le conteneur.
# Les dossiers de médias doivent être lisibles par ce compte ; pour un encodeur
# matériel, il doit aussi appartenir au groupe du périphérique (/dev/dri).
set -e

if [ -n "$PUID" ] && [ "$(id -u)" = "0" ]; then
  PGID="${PGID:-$PUID}"
  chown -R "$PUID:$PGID" /app/data /app/downloads
  exec su-exec "$PUID:$PGID" ./media-server "$@"
fi

exec ./media-server "$@"
