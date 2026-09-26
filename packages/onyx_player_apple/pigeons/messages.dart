import 'package:pigeon/pigeon.dart';

/// Le contrat entre le lecteur Dart et AetherEngine.
///
/// C'est la seule source de vérité : les deux côtés sont générés à partir
/// d'ici. Après toute modification :
///
/// ```
/// dart run pigeon --input pigeons/messages.dart
/// dart run tool/sync_tvos.dart
/// ```
///
/// Le second pas n'est pas facultatif. Pigeon n'importe `Flutter` que sous
/// `os(iOS)`, ce qui laisse l'Apple TV sans le module ; le script corrige la
/// garde puis recopie les sources vers `tvos/`.
///
/// Ne rien écrire à la main dans `messages.g.dart` / `Messages.g.swift`.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartOptions: DartOptions(),
    swiftOut:
        'darwin/onyx_player_apple/Sources/onyx_player_apple/Messages.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'onyx_player_apple',
  ),
)
/// Où en est le lecteur. Le même vocabulaire que sur Android, pour que les
/// deux sessions de l'app se lisent de la même façon.
enum OnyxApplePlaybackState {
  /// Rien de chargé, ou lecture arrêtée.
  idle,

  /// Ouverture, saut ou réserve vide : l'image n'avance pas en attendant des
  /// données.
  buffering,

  /// Prêt à jouer, ou en train de jouer.
  ready,

  /// Arrivé au bout. Terminal : il faut rouvrir pour relire.
  ended,
}

/// Pourquoi une ouverture a échoué.
///
/// Le détail porte une décision : un fichier que l'appareil ne sait pas lire
/// se rattrape par le transcodage du serveur, une source injoignable non.
enum OnyxApplePlayerErrorKind {
  unsupported,
  source,
  unknown,
}

/// Une piste qu'AetherEngine a énumérée.
class OnyxAppleTrack {
  OnyxAppleTrack({
    required this.id,
    required this.codec,
    required this.channels,
    required this.isDefault,
    required this.isForced,
    required this.isAtmos,
    required this.isBitmap,
    required this.isContainerStream,
    this.title,
    this.language,
  });

  /// L'index du flux dans le conteneur (`TrackInfo.id`), en texte : c'est ce
  /// que `PlaybackTrack.id` attend.
  final String id;
  final String? title;
  final String? language;

  /// Le nom libavcodec : `truehd`, `hdmv_pgs_subtitle`…
  final String codec;

  /// 0 pour une piste de sous-titres.
  final int channels;
  final bool isDefault;
  final bool isForced;

  /// E-AC-3 JOC : le lit d'objets passe tel quel jusqu'à la sortie.
  final bool isAtmos;

  /// Sous-titres image (PGS, VobSub, DVB), dessinés en bitmap.
  final bool isBitmap;

  /// Un vrai flux du conteneur. Faux pour un sous-titre externe posé par
  /// l'app, et pour les sous-titres CEA-608 que le moteur extrait de l'image :
  /// ni l'un ni l'autre n'a de place dans la numérotation des pistes du
  /// fichier, par laquelle le contrôleur retrouve leur langue.
  final bool isContainerStream;
}

class OnyxAppleVideoSize {
  OnyxAppleVideoSize({required this.width, required this.height});

  final int width;
  final int height;
}

/// Un instantané complet de l'état du lecteur.
///
/// Un seul objet plutôt qu'un événement par propriété, comme sur Android :
/// l'appelant n'a qu'un état à réconcilier.
class OnyxApplePlayerStatus {
  OnyxApplePlayerStatus({
    required this.playerId,
    required this.state,
    required this.isPlaying,
    required this.positionMs,
    required this.durationMs,
    required this.bufferedPositionMs,
    required this.audioTracks,
    required this.subtitleTracks,
    required this.videoFormat,
    this.videoSize,
    this.pixelAspectRatio,
    this.selectedAudioTrackId,
    this.selectedSubtitleTrackId,
    this.errorKind,
    this.errorMessage,
  });

  final int playerId;
  final OnyxApplePlaybackState state;

  /// L'image avance réellement, distinct de « on lui a demandé de lire ».
  final bool isPlaying;

  final int positionMs;

  /// 0 tant que la sonde du conteneur n'a pas répondu.
  final int durationMs;

  final int bufferedPositionMs;

  /// Null tant que la sonde n'a pas donné les dimensions.
  final OnyxAppleVideoSize? videoSize;

  /// Les pixels non carrés d'un DVD ou d'un MPEG-2 anamorphosé. Null quand ils
  /// sont carrés.
  final double? pixelAspectRatio;

  final List<OnyxAppleTrack> audioTracks;
  final List<OnyxAppleTrack> subtitleTracks;
  final String? selectedAudioTrackId;
  final String? selectedSubtitleTrackId;

  /// Ce que l'écran présente : `sdr`, `hdr10`, `hdr10plus`, `dolbyvision`,
  /// `hlg`. Déjà ramené à ce que l'écran sait faire — un Dolby Vision sur un
  /// écran HDR10 se lit `hdr10`.
  final String videoFormat;

  final OnyxApplePlayerErrorKind? errorKind;
  final String? errorMessage;
}

/// Un sous-titre image, placé en fractions de l'image vidéo.
///
/// Les fractions et non des pixels : la vue Flutter qui le peint n'a pas la
/// taille du canevas du PGS, et c'est elle qui sait où est l'image à l'écran.
class OnyxAppleSubtitleBitmap {
  OnyxAppleSubtitleBitmap({
    required this.png,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final Uint8List png;
  final double left;
  final double top;
  final double width;
  final double height;
}

/// Ce qu'il faut afficher comme sous-titres à cet instant.
///
/// Un flux à part du statut : il ne change qu'à chaque réplique, et une image
/// PGS n'a rien à faire dans un événement qui part quatre fois par seconde.
class OnyxAppleSubtitleFrame {
  OnyxAppleSubtitleFrame({
    required this.playerId,
    required this.lines,
    required this.bitmaps,
  });

  final int playerId;

  /// Les répliques texte, à peindre par la couche de sous-titres de l'app
  /// pour garder le même habillage partout.
  final List<String> lines;
  final List<OnyxAppleSubtitleBitmap> bitmaps;
}

/// Ce qu'AetherEngine sait dire de la lecture en cours, pour le journal.
class OnyxApplePlaybackStats {
  OnyxApplePlaybackStats({
    this.droppedFrames,
    this.observedFps,
    this.containerFps,
    this.videoCodec,
    this.videoDecoder,
    this.audioDecoder,
    this.videoBitrate,
    this.averageBitrateMbps,
    this.route,
    this.audioDelivery,
    this.container,
  });

  final int? droppedFrames;
  final double? observedFps;
  final double? containerFps;
  final String? videoCodec;
  final String? videoDecoder;
  final String? audioDecoder;

  /// Ce que le conteneur déclare, en bits par seconde.
  final int? videoBitrate;

  /// Ce qui a réellement transité depuis l'ouverture.
  final double? averageBitrateMbps;

  /// Le chemin qui sert la lecture : `loopback` (AVPlayer sur un remux local),
  /// `software` (décodage FFmpeg), `remoteBypass` (HLS du serveur lu tel
  /// quel). C'est la première chose à savoir d'une lecture qui chauffe.
  final String? route;

  /// `streamCopy`, `bridged`, `decoded`… : l'audio est-il passé tel quel.
  final String? audioDelivery;
  final String? container;
}

@HostApi()
abstract class OnyxApplePlayerApi {
  /// Crée un lecteur et rend son identifiant. La vue s'y rattache par cet
  /// identifiant, ce qui permet d'ouvrir un média avant que la vue n'existe
  /// et de survivre à sa reconstruction.
  int create();

  /// Détruit le lecteur. Sans appel, AetherEngine garde sa connexion, son
  /// serveur local et son décodeur pour toute la vie du processus.
  void release(int playerId);

  /// Charge [url] (le fichier du serveur, un fichier téléchargé ou une
  /// session HLS) en se plaçant à [startPositionMs] dans le même geste.
  ///
  /// Rend la main tout de suite : l'ouverture et ses pannes arrivent par le
  /// flux d'état, comme sur Android.
  void open(int playerId, String url, int startPositionMs, bool play);

  void play(int playerId);

  void pause(int playerId);

  void seekTo(int playerId, int positionMs);

  /// Décharge le média sans détruire le lecteur.
  void stop(int playerId);

  void setVolume(int playerId, double volume);

  void setRate(int playerId, double rate);

  /// Quelle langue audio charger d'emblée, la plus probable en premier. Posé
  /// avant l'ouverture : après, changer de piste reconstruit la session
  /// (une demi-seconde d'image noire).
  void setPreferredAudioLanguages(int playerId, List<String> priorities);

  void selectAudioTrack(int playerId, String trackId);

  /// Une piste de sous-titres du média, ou aucune si [trackId] est nul.
  void selectSubtitleTrack(int playerId, String? trackId);

  /// Pose (ou retire, avec null) le WebVTT que le serveur a produit.
  void setExternalSubtitle(
    int playerId,
    String? vttContent,
    String? language,
    String? title,
  );

  /// L'état à cet instant, pour s'amorcer sans attendre le premier événement.
  OnyxApplePlayerStatus status(int playerId);

  OnyxApplePlaybackStats stats(int playerId);
}

@EventChannelApi()
abstract class OnyxApplePlayerEventApi {
  /// Un flux unique pour tous les lecteurs ; [OnyxApplePlayerStatus.playerId]
  /// dit lequel.
  OnyxApplePlayerStatus statusChanged();

  /// Les sous-titres à afficher, à chaque changement de réplique.
  OnyxAppleSubtitleFrame subtitlesChanged();

  /// Le journal d'AetherEngine, par paquets de lignes, pour le journal par
  /// lecture de l'app (ADR-0026). Les secrets (ticket de lecture) y sont
  /// déjà masqués.
  List<String> engineLog();
}
