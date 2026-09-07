import 'package:pigeon/pigeon.dart';

/// Le contrat entre le lecteur Dart et ExoPlayer.
///
/// C'est la seule source de vérité : les deux côtés sont générés à partir
/// d'ici, donc un champ renommé casse la compilation sur la machine de
/// développement plutôt que la lecture sur le téléviseur. Après toute
/// modification :
///
/// ```
/// dart run pigeon --input pigeons/messages.dart
/// ```
///
/// Ne rien écrire à la main dans les fichiers `*.g.dart` / `Messages.g.kt`.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/src/main/kotlin/com/projectplayer/onyx_player_android/Messages.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.projectplayer.onyx_player_android',
    ),
    dartPackageName: 'onyx_player_android',
  ),
)
/// Où en est le lecteur, dans le vocabulaire d'ExoPlayer.
enum OnyxPlaybackState {
  /// Rien de chargé.
  idle,

  /// Chargé, mais pas assez de données pour avancer.
  buffering,

  /// Prêt à jouer, ou en train de jouer.
  ready,

  /// Arrivé au bout.
  ended,
}

/// Pourquoi une ouverture a échoué.
///
/// Le détail importe : c'est ce qui distingue un fichier qu'il faut transcoder
/// d'un réseau qui a lâché, et donc s'il faut réessayer ou changer de source.
enum OnyxPlayerErrorKind {
  /// Le conteneur ou le codec n'est pas lisible par cet appareil. C'est le cas
  /// qui bascule sur le transcodage.
  unsupported,

  /// La source n'a pas pu être lue : réseau, 404, connexion coupée.
  source,

  /// Tout le reste.
  unknown,
}

/// Comment l'image remplit sa surface.
///
/// Une `SurfaceView` est une couche du système : Flutter ne peut pas la mettre
/// à l'échelle, donc le cadrage se décide côté natif. C'est ce qui fait
/// répondre le pincement et le réglage « taille adaptative » sur Android.
enum OnyxVideoFit {
  /// L'image entière, avec des bandes s'il le faut.
  contain,

  /// Toute la hauteur, quitte à ce que les côtés sortent du cadre.
  ///
  /// C'est ce que « taille d'origine » veut dire sur un téléphone tenu à
  /// l'horizontale : la framing d'origine y arrive sous forme de bandes noires
  /// en haut et en bas dès que le film est plus large que l'écran, ce qui est
  /// le cas de la plupart. Sur un écran qu'on tient, les bandes valent moins
  /// que l'image.
  fillHeight,

  /// La surface entière, en rognant ce qui dépasse.
  cover,
}

/// Une piste que le moteur a énumérée.
class OnyxTrack {
  OnyxTrack({required this.id, this.title, this.language});

  final String id;
  final String? title;
  final String? language;
}

/// Les tampons, dans les unités d'ExoPlayer.
///
/// `PlaybackProfile` les exprime en octets et en secondes, parce que c'est le
/// vocabulaire de mpv ; `DefaultLoadControl` ne connaît que des millisecondes.
/// La traduction se fait côté Dart, où le profil est déjà résolu.
class OnyxLoadTuning {
  OnyxLoadTuning({
    required this.minBufferMs,
    required this.maxBufferMs,
    required this.bufferForPlaybackMs,
    required this.backBufferMs,
  });

  final int minBufferMs;
  final int maxBufferMs;

  /// Ce qu'il faut avoir en mémoire avant que l'image ne parte. Court : c'est
  /// du temps ajouté devant la première image, à chaque ouverture.
  final int bufferForPlaybackMs;

  /// Ce qu'on garde derrière la tête de lecture, pour que le retour de 10 s ne
  /// reparte pas sur le réseau.
  final int backBufferMs;
}

class OnyxVideoSize {
  OnyxVideoSize({required this.width, required this.height});

  final int width;
  final int height;
}

/// Un instantané complet de l'état du lecteur.
///
/// Un seul objet plutôt qu'un événement par propriété : l'appelant n'a qu'un
/// état à réconcilier, et deux champs ne peuvent pas se contredire en chemin.
class OnyxPlayerStatus {
  OnyxPlayerStatus({
    required this.playerId,
    required this.state,
    required this.isPlaying,
    required this.positionMs,
    required this.durationMs,
    required this.bufferedPositionMs,
    required this.audioTracks,
    required this.subtitleTracks,
    required this.subtitleCues,
    this.videoSize,
    this.selectedAudioTrackId,
    this.selectedSubtitleTrackId,
    this.errorKind,
    this.errorMessage,
  });

  final int playerId;
  final OnyxPlaybackState state;

  /// Le lecteur avance réellement — distinct de « on lui a demandé de lire ».
  final bool isPlaying;

  final int positionMs;

  /// 0 tant qu'ExoPlayer ne connaît pas la durée (flux en cours de sondage).
  final int durationMs;

  final int bufferedPositionMs;

  /// Null tant que le décodeur n'a pas annoncé les dimensions.
  final OnyxVideoSize? videoSize;

  /// Les pistes que le moteur a trouvées dans ce média.
  final List<OnyxTrack> audioTracks;
  final List<OnyxTrack> subtitleTracks;
  final String? selectedAudioTrackId;
  final String? selectedSubtitleTrackId;

  /// Les lignes de sous-titre à afficher maintenant. Rendues côté Flutter, pour
  /// que l'habillage soit le même que sur les autres plateformes.
  final List<String> subtitleCues;

  final OnyxPlayerErrorKind? errorKind;
  final String? errorMessage;
}

/// Ce qu'il faut pour répondre à « est-ce que c'est fluide ? » par un chiffre.
///
/// C'est le critère de recette du premier jalon : comparable au
/// `frame-drop-count` que le lecteur mpv journalise déjà en sortie.
class OnyxPlaybackStats {
  OnyxPlaybackStats({
    required this.droppedFrames,
    required this.renderedFrames,
  });

  final int droppedFrames;
  final int renderedFrames;
}

/// Ce que l'appareil sait décoder et restituer.
///
/// Tout est mesuré, rien n'est supposé : les décodeurs viennent de
/// `MediaCodecList`, le nombre de canaux et le passthrough des
/// `AudioCapabilities` d'ExoPlayer — c'est-à-dire de ce que l'ampli branché
/// déclare — et les formats HDR de l'écran lui-même. Un téléviseur et le
/// téléphone qui le pilote ne répondent donc pas la même chose, ce qui est
/// exactement le but.
class OnyxDeviceCapabilities {
  OnyxDeviceCapabilities({
    required this.videoMimeTypes,
    required this.audioMimeTypes,
    required this.passthroughAudioMimeTypes,
    required this.maxAudioChannels,
    required this.hdrFormats,
    required this.maxVideoBitDepth,
  });

  /// Les types MIME vidéo décodables, `video/hevc` et compagnie.
  final List<String> videoMimeTypes;

  /// Les types MIME audio décodables.
  final List<String> audioMimeTypes;

  /// Ceux que la sortie peut transmettre **sans les décoder**, jusqu'à l'ampli.
  ///
  /// C'est le seul chemin par lequel du Dolby Atmos arrive intact : le lit
  /// d'objets voyage dans le flux E-AC-3, et tout ce qui le décode le réduit à
  /// ses canaux. Vide sur un téléphone, garni sur un boîtier relié en HDMI.
  final List<String> passthroughAudioMimeTypes;

  /// Combien de canaux la sortie peut porter : 2 sur un haut-parleur, 6 ou 8
  /// derrière un ampli.
  final int maxAudioChannels;

  /// Les formats que l'écran accepte : `hdr10`, `hlg`, `hdr10plus`,
  /// `dolbyvision`.
  final List<String> hdrFormats;

  /// 10 dès qu'un décodeur matériel prend du 10 bits, 8 sinon.
  final int maxVideoBitDepth;
}

@HostApi()
abstract class OnyxPlayerApi {
  /// Crée un lecteur et rend son identifiant. La vue de rendu s'y rattache par
  /// cet identifiant, ce qui permet de créer le lecteur avant que la vue
  /// n'existe — et de survivre à sa reconstruction.
  int create();

  /// Détruit le lecteur. Sans appel, ExoPlayer garde son décodeur et sa
  /// connexion réseau ouverts.
  void release(int playerId);

  /// Charge [url] et se positionne à [startPositionMs] dans le même geste.
  /// Ouvrir puis chercher ferait payer deux fois la mise en mémoire tampon.
  ///
  /// [play] démarre la lecture dès que le média est prêt, sans second aller-
  /// retour : c'est ce que fait le passage à l'épisode suivant.
  void open(int playerId, String url, int startPositionMs, bool play);

  void play(int playerId);

  void pause(int playerId);

  void seekTo(int playerId, int positionMs);

  /// Décharge le média sans détruire le lecteur.
  ///
  /// C'est ici que le décodeur matériel est rendu — l'opération la plus chère
  /// du démontage. L'appeler tôt fait qu'elle se paie pendant qu'autre chose
  /// se passe à l'écran, plutôt qu'après.
  void stop(int playerId);

  void setVolume(int playerId, double volume);

  void setRate(int playerId, double rate);

  /// Quelle langue audio charger d'emblée, la plus probable en premier. Posé
  /// avant l'ouverture — après, changer de piste recharge le tampon.
  void setPreferredAudioLanguages(int playerId, List<String> priorities);

  void selectAudioTrack(int playerId, String trackId);

  /// Sélectionne une piste de sous-titres interne, ou aucune si [trackId] est
  /// nul.
  void selectSubtitleTrack(int playerId, String? trackId);

  /// Charge un WebVTT que le serveur a produit, en le posant à côté du média.
  ///
  /// Le contenu est passé plutôt qu'une URL : c'est le contrôleur qui l'a
  /// téléchargé, et le serveur a déjà recalé les temps sur l'offset du flux.
  void setExternalSubtitle(
    int playerId,
    String? vttContent,
    String? language,
    String? title,
  );

  /// Cherche à l'image près, ou au point-clé le plus proche pendant qu'on fait
  /// glisser la tête de lecture.
  void setExactSeek(int playerId, bool exact);

  void setVideoFit(int playerId, OnyxVideoFit fit);

  /// Impose la durée totale : en transcodage, le moteur ne voit que les
  /// segments déjà produits.
  void overrideDuration(int playerId, int totalMs);

  void applyTuning(int playerId, OnyxLoadTuning tuning);

  /// Ce que cet appareil-ci sait faire, décodeurs et sortie audio compris.
  ///
  /// mpv décodait tout en logiciel ; ExoPlayer dépend de MediaCodec, et la
  /// sortie audio dépend de ce qu'il y a au bout du HDMI. Demandé une fois, et
  /// envoyé au serveur : c'est ce qui lui permet de livrer le fichier tel quel
  /// au lieu d'un ré-encodage stéréo par défaut.
  OnyxDeviceCapabilities deviceCapabilities();

  /// L'état à cet instant. Les changements arrivent par le flux d'événements ;
  /// ceci sert à s'amorcer sans attendre le premier.
  OnyxPlayerStatus status(int playerId);

  /// Les compteurs d'images du rendu vidéo.
  OnyxPlaybackStats stats(int playerId);
}

@EventChannelApi()
abstract class OnyxPlayerEventApi {
  /// Un flux unique pour tous les lecteurs — [OnyxPlayerStatus.playerId] dit
  /// lequel. Un canal par lecteur coûterait une négociation à chaque ouverture
  /// pour distinguer des instances qui n'existent jamais à plus de deux.
  OnyxPlayerStatus statusChanged();
}
