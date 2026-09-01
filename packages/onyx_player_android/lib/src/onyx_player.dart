import 'messages.g.dart';

export 'messages.g.dart'
    show
        OnyxPlaybackState,
        OnyxPlaybackStats,
        OnyxPlayerErrorKind,
        OnyxPlayerStatus,
        OnyxVideoSize;

/// Un lecteur ExoPlayer, vu de Dart.
///
/// La classe ne fait presque rien : elle possède un identifiant, relaie les
/// commandes au contrat généré, et filtre le flux d'état global sur ce qui la
/// concerne. Toute la logique de lecture — reprise, pistes, sessions HLS,
/// préférences — appartient au contrôleur partagé de l'app, pas ici. C'est ce
/// qui permet au même contrôleur de piloter mpv ailleurs.
/// Le flux d'état natif, ouvert une seule fois pour tout le processus.
///
/// Pigeon crée un `EventChannel` **neuf à chaque appel** de [statusChanged], et
/// deux canaux du même nom se disputent un seul émetteur côté natif : le second
/// écouteur remplace le puits du premier, et l'annulation du premier le coupe
/// pour tout le monde. Le passage à l'épisode suivant construit le lecteur
/// suivant avant de détruire le précédent — deux lecteurs vivants au même
/// instant n'a donc rien de théorique ici.
Stream<OnyxPlayerStatus>? _sharedStatuses;

Stream<OnyxPlayerStatus> _nativeStatuses() =>
    _sharedStatuses ??= statusChanged();

class OnyxPlayer {
  OnyxPlayer._(this._id, this._api);

  final int _id;
  final OnyxPlayerApi _api;

  bool _released = false;

  /// Crée le lecteur natif. Rien n'est chargé tant qu'[open] n'est pas appelé.
  static Future<OnyxPlayer> create() async {
    final api = OnyxPlayerApi();
    final id = await api.create();
    return OnyxPlayer._(id, api);
  }

  /// L'identifiant à passer à la vue de rendu. La vue se rattache au lecteur
  /// plutôt que de le créer, pour que Flutter puisse la reconstruire sans
  /// interrompre la lecture.
  int get id => _id;

  /// Chaque changement d'état de *ce* lecteur.
  ///
  /// Le natif n'émet qu'un flux pour tous ; le tri se fait ici, sur l'identifiant.
  Stream<OnyxPlayerStatus> get statuses =>
      _nativeStatuses().where((status) => status.playerId == _id);

  /// Charge [url] en se positionnant à [startPosition] dans le même geste.
  Future<void> open(String url, {Duration startPosition = Duration.zero}) {
    return _api.open(_id, url, startPosition.inMilliseconds);
  }

  Future<void> play() => _api.play(_id);

  Future<void> pause() => _api.pause(_id);

  Future<void> seekTo(Duration position) =>
      _api.seekTo(_id, position.inMilliseconds);

  /// L'état à cet instant, pour s'amorcer sans attendre le premier événement.
  Future<OnyxPlayerStatus> status() => _api.status(_id);

  /// Les compteurs d'images du rendu. C'est le chiffre qui dit si la lecture
  /// est fluide, et le seul verdict qui ne se discute pas.
  Future<OnyxPlaybackStats> stats() => _api.stats(_id);

  /// Détruit le lecteur natif. Sans appel, ExoPlayer garde son décodeur et sa
  /// connexion ouverts pour toute la vie du processus.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _api.release(_id);
  }
}
