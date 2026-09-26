/// Le lecteur vidéo d'Onyx sur iPhone, Mac et Apple TV.
///
/// Deux objets, et rien d'autre : [OnyxApplePlayer], qui pilote une instance
/// d'AetherEngine, et [OnyxApplePlayerView], la vue native où elle dessine.
/// Le serveur envoie le fichier tel quel (Direct Play) : le démultiplexage,
/// la conversion audio et les sous-titres se font sur l'appareil. La logique
/// de lecture appartient au contrôleur partagé de l'app — ce paquet ne sait
/// rien des médias, des pistes par défaut ni des sessions.
library;

export 'src/onyx_apple_player.dart';
export 'src/onyx_apple_player_view.dart';
