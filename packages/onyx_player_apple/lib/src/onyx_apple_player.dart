import 'messages.g.dart';
import 'messages.g.dart' as pigeon show engineLog;

export 'messages.g.dart'
    show
        OnyxApplePlaybackState,
        OnyxApplePlaybackStats,
        OnyxApplePlayerErrorKind,
        OnyxApplePlayerStatus,
        OnyxAppleSubtitleBitmap,
        OnyxAppleSubtitleFrame,
        OnyxAppleTrack,
        OnyxAppleVideoSize;

/// Les flux natifs, ouverts une seule fois pour tout le processus.
///
/// Pigeon crée un `EventChannel` neuf à chaque appel, et deux canaux du même
/// nom se disputent un seul émetteur côté natif : le second écouteur remplace
/// le premier, et l'annulation de l'un coupe l'autre. Le passage à l'épisode
/// suivant construit le lecteur suivant avant de détruire le précédent, donc
/// deux lecteurs vivants au même instant arrivent vraiment. Même raison que
/// sur Android.
Stream<OnyxApplePlayerStatus>? _sharedStatuses;
Stream<OnyxAppleSubtitleFrame>? _sharedSubtitles;
Stream<List<String>>? _sharedEngineLog;

Stream<OnyxApplePlayerStatus> _nativeStatuses() =>
    _sharedStatuses ??= statusChanged().asBroadcastStream();

Stream<OnyxAppleSubtitleFrame> _nativeSubtitles() =>
    _sharedSubtitles ??= subtitlesChanged().asBroadcastStream();

/// Un lecteur AetherEngine, vu de Dart.
///
/// La classe ne fait presque rien : elle possède un identifiant, relaie les
/// commandes au contrat généré et filtre les flux globaux sur ce qui la
/// concerne. Toute la logique de lecture appartient au contrôleur de l'app.
class OnyxApplePlayer {
  OnyxApplePlayer._(this._id, this._api);

  final int _id;
  final OnyxApplePlayerApi _api;

  bool _released = false;

  /// Le journal d'AetherEngine, tous lecteurs confondus, par paquets de
  /// lignes. Le ticket de lecture y est déjà masqué.
  static Stream<List<String>> get engineLog =>
      _sharedEngineLog ??= pigeon
          .engineLog()
          .map((lines) => lines.cast<String>())
          .asBroadcastStream();

  /// Crée le lecteur natif. Rien n'est chargé tant qu'[open] n'est pas appelé.
  static Future<OnyxApplePlayer> create() async {
    final api = OnyxApplePlayerApi();
    final id = await api.create();
    return OnyxApplePlayer._(id, api);
  }

  /// L'identifiant à passer à la vue. La vue se rattache au lecteur plutôt
  /// que de le créer, pour que Flutter puisse la reconstruire sans
  /// interrompre la lecture.
  int get id => _id;

  /// Chaque changement d'état de *ce* lecteur.
  Stream<OnyxApplePlayerStatus> get statuses =>
      _nativeStatuses().where((status) => status.playerId == _id);

  /// Les sous-titres de *ce* lecteur, à chaque changement de réplique.
  Stream<OnyxAppleSubtitleFrame> get subtitles =>
      _nativeSubtitles().where((frame) => frame.playerId == _id);

  /// Charge [url] (fichier du serveur, chemin d'un téléchargement ou session
  /// HLS) en se plaçant à [startPosition] dans le même geste.
  Future<void> open(
    String url, {
    Duration startPosition = Duration.zero,
    bool play = false,
  }) =>
      _api.open(_id, url, startPosition.inMilliseconds, play);

  Future<void> play() => _api.play(_id);

  Future<void> pause() => _api.pause(_id);

  Future<void> seekTo(Duration position) =>
      _api.seekTo(_id, position.inMilliseconds);

  /// Décharge le média sans détruire le lecteur, ni rendre le mode de
  /// l'écran : l'épisode suivant arrive souvent juste derrière.
  Future<void> stop() => _api.stop(_id);

  Future<void> setVolume(double volume) => _api.setVolume(_id, volume);

  Future<void> setRate(double rate) => _api.setRate(_id, rate);

  /// Posé avant l'ouverture : changer d'audio après coup reconstruit la
  /// session.
  Future<void> setPreferredAudioLanguages(List<String> priorities) =>
      _api.setPreferredAudioLanguages(_id, priorities);

  Future<void> selectAudioTrack(String trackId) =>
      _api.selectAudioTrack(_id, trackId);

  /// [trackId] nul coupe les sous-titres.
  Future<void> selectSubtitleTrack(String? trackId) =>
      _api.selectSubtitleTrack(_id, trackId);

  /// Pose (ou retire, avec null) le WebVTT que le serveur a produit.
  Future<void> setExternalSubtitle(
    String? vtt, {
    String? language,
    String? title,
  }) =>
      _api.setExternalSubtitle(_id, vtt, language, title);

  /// L'état à cet instant, pour s'amorcer sans attendre le premier événement.
  Future<OnyxApplePlayerStatus> status() => _api.status(_id);

  Future<OnyxApplePlaybackStats> stats() => _api.stats(_id);

  /// Détruit le lecteur natif et rend le mode de l'écran. Sans appel,
  /// AetherEngine garde sa connexion et son serveur local ouverts.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _api.release(_id);
  }
}
