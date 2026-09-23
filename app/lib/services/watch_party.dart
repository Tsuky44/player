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

  /// En train de remplir son tampon ou de chercher : sa position est en
  /// transit, la comparer à la séance ferait chercher en boucle.
  bool get isBusy;

  bool get isPlaying;
  Duration get position;

  Future<void> applyPlaying(bool playing);
  Future<void> applySeek(Duration position);

  /// La séance est passée à un autre média (l'épisode suivant, en général).
  void openMedia(HomeMediaItem media, Duration position, {required bool playing});
}

/// Une séance « Regarder ensemble » à laquelle cet appareil participe.
///
/// Il n'y en a qu'une à la fois, dans [active]. Elle survit aux changements
/// d'écran du lecteur (épisode suivant, relance) : c'est le lecteur qui s'y
/// accroche en s'ouvrant, et s'en détache en se fermant.
class WatchPartySession extends ChangeNotifier {
  WatchPartySession._(this.api, this.accountId, WatchPartySnapshot initial)
      : _snapshot = initial,
        _announcedVersion = initial.version {
    unawaited(_pollLoop());
    _driftTimer = Timer.periodic(_driftCheckInterval, (_) => _reconcile());
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

  /// L'écart toléré après un geste explicite (pause, recherche) : au-delà, on
  /// cale tout le monde sur la même image.
  static const Duration _actionTolerance = Duration(milliseconds: 1200);

  /// L'écart toléré en lecture continue. Plus large : une recherche coûte un
  /// rechargement du tampon, bien plus gênant qu'un décalage de deux secondes.
  static const Duration _driftTolerance = Duration(milliseconds: 2500);
  static const Duration _driftCheckInterval = Duration(seconds: 3);

  /// Délai minimal entre deux corrections automatiques, le temps qu'une
  /// recherche — parfois une reconstruction de session HLS — se pose.
  static const Duration _correctionCooldown = Duration(seconds: 6);

  final ApiClient api;

  /// Le compte (donc le serveur) qui héberge la séance.
  final String accountId;

  WatchPartySnapshot _snapshot;
  WatchPartySnapshot get snapshot => _snapshot;
  String get code => _snapshot.code;
  List<WatchPartyMember> get members => _snapshot.members;

  WatchPartyPlayer? _player;
  Timer? _driftTimer;
  CancelToken? _pollCancel;
  bool _closed = false;
  bool get isClosed => _closed;
  int _announcedVersion;
  Duration? _lastCorrection;

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
    final json = await api.createWatchParty(
      mediaId: mediaId,
      positionSeconds: position.inMilliseconds / 1000,
      playing: playing,
    );
    return _open(api, accountId, json);
  }

  static Future<WatchPartySession> join({
    required ApiClient api,
    required String accountId,
    required String code,
  }) async {
    final json = await api.joinWatchParty(normalizeCode(code));
    return _open(api, accountId, json);
  }

  static WatchPartySession _open(
      ApiClient api, String accountId, Map<String, dynamic> json) {
    final previous = active.value;
    if (previous != null) unawaited(previous.leave());
    final session = WatchPartySession._(
      api,
      accountId,
      WatchPartySnapshot.fromJson(json, receivedAt: _now),
    );
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
    _reconcile(explicit: true);
  }

  void detach(WatchPartyPlayer player) {
    if (identical(_player, player)) _player = null;
  }

  /// Recale le lecteur tout de suite — à sa première image, typiquement.
  void resync() => _reconcile(explicit: true);

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
    _accept(WatchPartySnapshot.fromJson(json, receivedAt: _now));
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
        _accept(WatchPartySnapshot.fromJson(json, receivedAt: _now));
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
      _reconcile(explicit: true);
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

  /// Aligne le lecteur sur la séance.
  ///
  /// [explicit] après un geste (pause, recherche, arrivée) : tolérance serrée,
  /// tout le monde sur la même image. Sinon, simple surveillance de la dérive
  /// en lecture continue, avec une tolérance large et un délai entre deux
  /// corrections.
  void _reconcile({bool explicit = false}) {
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
        _player = null;
        player.openMedia(media, snap.expectedPosition(_now),
            playing: snap.playing);
      }
      return;
    }

    if (!player.isReady) return;

    if (player.isPlaying != snap.playing) {
      unawaited(player.applyPlaying(snap.playing));
    }

    if (player.isBusy) return;
    final now = _now;
    if (!explicit &&
        _lastCorrection != null &&
        now - _lastCorrection! < _correctionCooldown) {
      return;
    }
    final expected = snap.expectedPosition(now);
    final drift = (player.position - expected).abs();
    final tolerance = explicit ? _actionTolerance : _driftTolerance;
    if (drift > tolerance) {
      _lastCorrection = now;
      unawaited(player.applySeek(expected));
    }
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
    _driftTimer?.cancel();
    _pollCancel?.cancel();
    _player = null;
    if (identical(active.value, this)) active.value = null;
    notifyListeners();
    // Laisse aux écouteurs le temps de lire l'annonce de fin.
    Future<void>.delayed(const Duration(seconds: 1), _notices.close);
  }
}
