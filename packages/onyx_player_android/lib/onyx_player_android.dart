/// Le lecteur vidéo d'Onyx sur Android.
///
/// Deux objets, et rien d'autre : [OnyxPlayer], qui pilote une instance
/// ExoPlayer native, et [OnyxPlayerView], la `SurfaceView` où elle dessine. La
/// logique de lecture appartient au contrôleur partagé de l'app — ce paquet ne
/// sait rien des médias, des pistes ni des sessions.
library;

export 'src/onyx_player.dart';
export 'src/onyx_player_view.dart';
