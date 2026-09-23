import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../models/watch_party.dart';
import 'api_client.dart';

/// Ce que la séance attend du lecteur ouvert sur cet appareil.
///
/// Les méthodes `apply…` appliquent un état venu des autres : elles ne doivent
/// **pas** être renvoyées à la séance, sans quoi chaque geste ferait écho à
/// l'infini. Seuls les gestes de la personne devant l'écran partent, par
/// [WatchPartySession.sendPlaying], [WatchPartySession.sendSeek] et
/// [WatchPartySession.sendMedia].
abstract interface class WatchPartyPlayer {
  int get mediaId;

  /// La première image est là : avant, position et lecture ne veulent rien
  /// dire, et corriger un lecteur qui démarre ne ferait que le ralentir.
  bool get isReady;

  /// Le lecteur charge : première image pas encore là, tampon vide,
  /// reconstruction de session. C'est ce qui fait attendre les autres.
  bool get isLoading;

  /// Sa position est en transit (chargement, recherche qui se pose) : la
  /// comparer à la séance ferait corriger à contretemps.
  bool get isBusy;

  bool get isPlaying;
  Duration get position;

  Future<void> applyPlaying(bool playing);
  Future<void> applySeek(Duration position);

  /// Multiplie la vitesse choisie par [factor], de quelques pour cent au
  /// plus : c'est ainsi qu'on rattrape un petit écart sans rien couper.
  Future<void> applyRateFactor(double factor);

  /// La séance est passée à un autre média (l'épisode suivant, en général).
  void openMedia(HomeMediaItem media, Duration position, {required bool playing});
}

/// Une séance « Regarder ensemble » à laquelle cet appareil participe.
///
/// Il n'y en a qu'une à la fois, dans [active]. Elle survit aux changements
/// d'écran du lecteur (épisode suivant, relance) : c'est le lecteur qui s'y
/// accroche en s'ouvrant, et s'en détache en se fermant.
///
/// La synchronisation se fait en trois étages :
/// - **l'attente** : un appareil qui charge le dit au serveur, qui fige la
///   séance pour tout le monde jusqu'à ce qu'il soit prêt — personne ne rate
///   rien, et tout le monde repart ensemble ;
/// - **la vitesse** : un écart de quelques dixièmes se rattrape en accélérant
///   ou en ralentissant de quelques pour cent, sans coupure ;
/// - **la recherche** : réservée aux gros écarts, et aux pauses, où elle ne
///   coûte rien.
class WatchPartySession extends ChangeNotifier {
  WatchPartySession._(this.api, this.accountId, WatchPartySnapshot initial)
      : _snapshot = initial,
        _announcedVersion = initial.version {
    unawaited(_pollLoop());
    _ticker = Timer.periodic(_tickInterval, (_) => _tick());
    unawaited(_probeLatency());
  }

  /// La clé de compte quand le client n'en désigne aucun (installation à un
  /// seul serveur, d'avant le carnet de comptes).
  static const String defaultAccountKey = '_default';

  /// La séance en cours sur cet appareil, s'il y en a une.
  static final ValueNotifier<WatchPartySession?> active = ValueNotifier(null);

  /// Horloge monotone : la synchronisation ne dépend que de durées mesurées
  /// ici, jamais de l'heure du serveur.
  static final Stopwatch _clock = Stopwatch()..start();
  static Duration get _now => _clock.elapsed;

  static const Duration _tickInterval = Duration(milliseconds: 250);

  /// Un chargement plus court que ça ne fait pas attendre les autres : un
  /// hoquet de tampon se rattrape par la vitesse.
  static const Duration _loadingGrace = Duration(milliseconds: 400);

  /// En pause, tout le monde sur la même image : une recherche à l'arrêt ne
  /// se voit pas.
  static const double _pausedTolerance = 0.2;

  /// En lecture, au-delà de cet écart on cherche ; en dessous, on joue sur la
  /// vitesse.
  static const double _seekThreshold = 1.5;

  /// L'écart qui déclenche le rattrapage par la vitesse, et celui qui l'arrête.
  static const double _nudgeStart = 0.08;
  static const double _nudgeStop = 0.03;

  /// Combien de vitesse par seconde d'écart, et pas plus que [_maxNudge] :
  /// au-delà de 8 %, un changement de vitesse commence à s'entendre.
  static const double _nudgeGain = 0.2;
  static const double _maxNudge = 0.08;

  /// Délai minimal entre deux recherches automatiques, le temps qu'une
  /// recherche — parfois une reconstruction de session HLS — se pose.
  static const Duration _seekCooldown = Duration(seconds: 2);

  final ApiClient api;

  /// Le compte (donc le serveur) qui héberge la séance.
  final String accountId;

  WatchPartySnapshot _snapshot;
  WatchPartySnapshot get snapshot => _snapshot;
  String get code => _snapshot.code;
  List<WatchPartyMember> get members => _snapshot.members;

  /// Qui la séance attend, à afficher tant que ça dure.
  String? get waitingMessage {
    final names = _snapshot.waitingFor;
    if (names.isEmpty) return null;
    return 'En attente de ${names.join(', ')}…';
  }

  WatchPartyPlayer? _player;
  Timer? _ticker;
  int _ticks = 0;
  CancelToken? _pollCancel;
  bool _closed = false;
  bool get isClosed => _closed;
  int _announcedVersion;
  Duration? _lastSeek;

  /// Le trajet aller-retour le plus court mesuré récemment : sa moitié est le
  /// retard avec lequel l'état du serveur arrive ici.
  final List<Duration> _rttSamples = [];
  Duration get _oneWay {
    if (_rttSamples.isEmpty) return Duration.zero;
    final best = _rttSamples.reduce((a, b) => a < b ? a : b);
    return best ~/ 2;
  }

  /// Le facteur de vitesse appliqué en ce moment pour rattraper un écart.
  double _rateFactor = 1;

  /// Depuis quand le lecteur charge, et si ce chargement-ci a déjà été
  /// signalé. Un chargement signalé que le serveur a cessé d'attendre (trop
  /// long) ne l'est pas une seconde fois : il bloquerait tout le monde en
  /// boucle.
  Duration? _loadingSince;
  bool _loadingReported = false;
  bool _loadingInFlight = false;

  /// Des gestes locaux partis et pas encore confirmés. Tant qu'il y en a, la
  /// séance connue ici est en retard sur l'écran : la recaler dessus
  /// annulerait la pause qu'on vient de demander.
  int _pendingLocal = 0;

  /// Un changement de média parti d'ici, pas encore confirmé par le serveur :
  /// sans lui, le lecteur du nouvel épisode verrait la séance encore sur
  /// l'ancien et y retournerait.
  ({int mediaId, int sinceVersion})? _localMediaChange;

  final StreamController<String> _notices = StreamController.broadcast();

  /// Ce qu'il faut annoncer : les gestes des autres, les arrivées, les
  /// départs, la fin de la séance.
  Stream<String> get notices => _notices.stream;

  // --- Ouverture ---------------------------------------------------------

  static Future<WatchPartySession> create({
    required ApiClient api,
    required String accountId,
    required int mediaId,
    required Duration position,
    required bool playing,
  }) async {
    final sent = _now;
    final json = await api.createWatchParty(
      mediaId: mediaId,
      positionSeconds: position.inMilliseconds / 1000,
      playing: playing,
    );
    return _open(api, accountId, json, _now - sent);
  }

  static Future<WatchPartySession> join({
    required ApiClient api,
    required String accountId,
    required String code,
  }) async {
    final sent = _now;
    final json = await api.joinWatchParty(normalizeCode(code));
    return _open(api, accountId, json, _now - sent);
  }

  static WatchPartySession _open(ApiClient api, String accountId,
      Map<String, dynamic> json, Duration rtt) {
    final previous = active.value;
    if (previous != null) unawaited(previous.leave());
    final session = WatchPartySession._(
      api,
      accountId,
      WatchPartySnapshot.fromJson(json, receivedAt: _now - rtt ~/ 2),
    );
    session._noteRtt(rtt);
    active.value = session;
    return session;
  }

  /// Ce que la personne a tapé, dans la forme du serveur : majuscules, sans
  /// espace ni tiret.
  static String normalizeCode(String raw) =>
      raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  // --- Lecteur -------------------------------------------------------------

  void attach(WatchPartyPlayer player) {
    _player = player;
    _rateFactor = 1;
    _loadingSince = null;
    _loadingReported = false;
    _reconcile();
  }

  void detach(WatchPartyPlayer player) {
    if (!identical(_player, player)) return;
    _resetRate(player);
    _player = null;
  }

  /// Recale le lecteur tout de suite — à sa première image, typiquement.
  void resync() {
    _reportLoading();
    _reconcile();
  }

  // --- Gestes locaux -------------------------------------------------------

  Future<void> sendPlaying(bool playing, Duration position) =>
      _send(playing ? 'play' : 'pause', playing: playing, position: position);

  Future<void> sendSeek(Duration position, {required bool playing}) =>
      _send('seek', playing: playing, position: position);

  /// Passe la séance à un autre média, depuis son début.
  Future<void> sendMedia(int mediaId) {
    _localMediaChange = (mediaId: mediaId, sinceVersion: _snapshot.version);
    return _send('media', mediaId: mediaId, playing: true);
  }

  Future<void> _send(
    String action, {
    bool? playing,
    Duration? position,
    int? mediaId,
  }) async {
    if (_closed) return;
    _pendingLocal++;
    final sent = _now;
    Map<String, dynamic> json;
    try {
      json = await api.updateWatchParty(
        code,
        memberId: _snapshot.memberId,
        action: action,
        playing: playing,
        positionSeconds:
            position == null ? null : position.inMilliseconds / 1000,
        mediaId: mediaId,
      );
    } on DioException catch (e) {
      if (_isGone(e)) {
        _end('La séance est terminée.');
      } else {
        debugPrint('WatchParty: $action non transmis: ${e.type.name}');
      }
      return;
    } finally {
      _pendingLocal--;
    }
    _acceptTimed(json, sent);
  }

  // --- Chargement ----------------------------------------------------------

  /// Dit au serveur quand ce lecteur charge, et quand il est de nouveau prêt.
  void _reportLoading() {
    final player = _player;
    if (_closed || player == null || _loadingInFlight) return;
    // Un lecteur sur un autre média que la séance est en train de la quitter
    // ou de la rejoindre : son état ne dit rien de celui-ci.
    if (player.mediaId != _snapshot.mediaId) return;

    final now = _now;
    if (player.isLoading) {
      _loadingSince ??= now;
      if (_loadingReported || _snapshot.waitingForYou) {
        _loadingReported = true;
        return;
      }
      // Le démarrage attend sans délai de grâce : c'est tout le point de
      // partir ensemble.
      if (player.isReady && now - _loadingSince! < _loadingGrace) return;
      _loadingReported = true;
      unawaited(_sendLoading(true, player.position));
    } else {
      _loadingSince = null;
      _loadingReported = false;
      if (_snapshot.waitingForYou) unawaited(_sendLoading(false, null));
    }
  }

  Future<void> _sendLoading(bool loading, Duration? position) async {
    _loadingInFlight = true;
    final sent = _now;
    try {
      final json = await api.updateWatchParty(
        code,
        memberId: _snapshot.memberId,
        action: 'loading',
        loading: loading,
        positionSeconds:
            position == null ? null : position.inMilliseconds / 1000,
      );
      _acceptTimed(json, sent);
    } on DioException catch (e) {
      if (_isGone(e)) _end('La séance est terminée.');
    } catch (e) {
      debugPrint('WatchParty: réponse illisible: $e');
    } finally {
      _loadingInFlight = false;
    }
  }

  // --- Réception -----------------------------------------------------------

  Future<void> _pollLoop() async {
    var failures = 0;
    while (!_closed) {
      final cancel = CancelToken();
      _pollCancel = cancel;
      try {
        final json = await api.pollWatchParty(
          code,
          memberId: _snapshot.memberId,
          since: _snapshot.version,
          cancelToken: cancel,
        );
        failures = 0;
        _accept(WatchPartySnapshot.fromJson(json, receivedAt: _now - _oneWay));
      } on DioException catch (e) {
        if (_closed || CancelToken.isCancel(e)) return;
        if (_isGone(e)) {
          _end('La séance est terminée.');
          return;
        }
        // Réseau coupé, serveur qui redémarre : on réessaie sans fin, en
        // espaçant. Le serveur oublie un participant muet au bout de 50 s ;
        // le 404 qui suivra dira alors que la séance est perdue.
        failures++;
        final backoff = Duration(seconds: failures > 4 ? 10 : 1 << failures);
        await Future<void>.delayed(backoff);
      } catch (e) {
        debugPrint('WatchParty: réponse illisible: $e');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  /// Mesure le trajet aller-retour : un long-poll sur une version déjà
  /// dépassée répond sur-le-champ. Répété, parce que le réseau change — un
  /// téléphone qui passe du Wi-Fi à la 4G.
  Future<void> _probeLatency() async {
    while (!_closed) {
      final sent = _now;
      try {
        final json = await api.pollWatchParty(
          code,
          memberId: _snapshot.memberId,
          since: 0,
        );
        _acceptTimed(json, sent);
      } on DioException catch (e) {
        if (_isGone(e)) return;
      } catch (_) {}
      await Future<void>.delayed(
          Duration(seconds: _rttSamples.length < 3 ? 1 : 15));
    }
  }

  void _noteRtt(Duration rtt) {
    _rttSamples.add(rtt);
    if (_rttSamples.length > 6) _rttSamples.removeAt(0);
  }

  /// Accepte la réponse d'une requête partie à [sent] : son trajet sert aussi
  /// de mesure.
  void _acceptTimed(Map<String, dynamic> json, Duration sent) {
    if (_closed) return;
    final rtt = _now - sent;
    _noteRtt(rtt);
    _accept(WatchPartySnapshot.fromJson(json, receivedAt: _now - rtt ~/ 2));
  }

  static bool _isGone(DioException e) {
    final status = e.response?.statusCode;
    return status == 404 || status == 403;
  }

  void _accept(WatchPartySnapshot next) {
    if (_closed) return;
    // Un long-poll et la réponse à un geste peuvent se croiser : le plus
    // ancien des deux ne doit pas défaire le plus récent.
    if (next.version < _snapshot.version) return;
    final changed = next.version > _snapshot.version;
    _snapshot = next;
    if (_localMediaChange != null &&
        next.mediaId == _localMediaChange!.mediaId) {
      _localMediaChange = null;
    }
    if (changed) {
      _announce(next.lastAction);
      _reportLoading();
      _reconcile();
    }
    notifyListeners();
  }

  void _announce(WatchPartyAction? action) {
    if (action == null || action.version <= _announcedVersion) return;
    _announcedVersion = action.version;
    if (action.byYou) return;
    final who = action.username.isEmpty ? 'Quelqu’un' : action.username;
    final text = switch (action.kind) {
      'play' => '$who a relancé la lecture',
      'pause' => '$who a mis en pause',
      'seek' => '$who a déplacé la lecture',
      'media' => '$who a lancé un autre épisode',
      'join' => '$who a rejoint la séance',
      'leave' => '$who a quitté la séance',
      _ => null,
    };
    if (text != null) _notices.add(text);
  }

  // --- Recalage -------------------------------------------------------------

  void _tick() {
    _ticks++;
    _reportLoading();
    // La dérive se mesure deux fois par seconde : assez pour doser la vitesse,
    // sans lire la position plus souvent que le moteur ne la rafraîchit.
    if (_ticks.isEven) _reconcile();
  }

  /// Aligne le lecteur sur la séance.
  void _reconcile() {
    final player = _player;
    if (_closed || player == null || _pendingLocal > 0) return;
    final snap = _snapshot;

    if (snap.mediaId != player.mediaId) {
      final pending = _localMediaChange;
      if (pending != null &&
          pending.mediaId == player.mediaId &&
          snap.version <= pending.sinceVersion) {
        return;
      }
      final media = snap.media;
      if (media != null) {
        _resetRate(player);
        _player = null;
        player.openMedia(media, snap.expectedPosition(_now),
            playing: snap.playing);
      }
      return;
    }

    if (!player.isReady) return;

    // Attendre les autres, c'est être en pause. Mais on ne se met pas en
    // pause pour soi-même tant qu'on charge : le moteur continue de remplir
    // son tampon et repartira de lui-même. Une fois prêt, en revanche, on
    // attend que le serveur relance tout le monde, pour partir ensemble.
    final readyButHeld = snap.waitingForYou && !player.isLoading;
    final wantPlaying =
        snap.playing && snap.waitingFor.isEmpty && !readyButHeld;
    if (player.isPlaying != wantPlaying) {
      unawaited(player.applyPlaying(wantPlaying));
    }

    if (player.isBusy || snap.waitingForYou) {
      _resetRate(player);
      return;
    }

    final now = _now;
    final expected = snap.expectedPosition(now);
    final drift =
        (player.position - expected).inMicroseconds / Duration.microsecondsPerSecond;
    final seekAllowed = _lastSeek == null || now - _lastSeek! >= _seekCooldown;

    if (!snap.isRunning) {
      // Figée (pause, ou attente) : tout le monde sur la même image.
      _resetRate(player);
      if (drift.abs() > _pausedTolerance && seekAllowed) {
        _lastSeek = now;
        unawaited(player.applySeek(expected));
      }
      return;
    }

    if (drift.abs() > _seekThreshold) {
      _resetRate(player);
      if (seekAllowed) {
        _lastSeek = now;
        unawaited(player.applySeek(expected));
      }
      return;
    }

    final nudging = _rateFactor != 1;
    if (drift.abs() < _nudgeStop || (!nudging && drift.abs() < _nudgeStart)) {
      _resetRate(player);
      return;
    }
    // En avance, on ralentit ; en retard, on accélère.
    final factor = 1 - (drift * _nudgeGain).clamp(-_maxNudge, _maxNudge);
    if ((factor - _rateFactor).abs() >= 0.005) {
      _rateFactor = factor;
      unawaited(player.applyRateFactor(factor));
    }
  }

  void _resetRate(WatchPartyPlayer player) {
    if (_rateFactor == 1) return;
    _rateFactor = 1;
    unawaited(player.applyRateFactor(1));
  }

  // --- Fin -------------------------------------------------------------------

  /// Quitte la séance. Les autres continuent sans cet appareil.
  Future<void> leave() async {
    if (_closed) return;
    final memberId = _snapshot.memberId;
    _close();
    try {
      await api.leaveWatchParty(code, memberId: memberId);
    } on DioException catch (e) {
      debugPrint('WatchParty: départ non transmis: ${e.type.name}');
    }
  }

  void _end(String notice) {
    if (_closed) return;
    _notices.add(notice);
    _close();
  }

  void _close() {
    _closed = true;
    _ticker?.cancel();
    _pollCancel?.cancel();
    final player = _player;
    if (player != null) _resetRate(player);
    _player = null;
    if (identical(active.value, this)) active.value = null;
    notifyListeners();
    // Laisse aux écouteurs le temps de lire l'annonce de fin.
    Future<void>.delayed(const Duration(seconds: 1), _notices.close);
  }
}
