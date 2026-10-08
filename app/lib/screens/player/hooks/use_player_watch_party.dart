import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../models/models.dart';
import '../../../services/api_client.dart';
import '../../../services/watch_party.dart';
import 'use_player_controller.dart';

/// Le lecteur dans une séance « Regarder ensemble » : à quelle séance il est
/// accroché, ce qu'il en annonce, et comment la séance le pilote.
///
/// La séance survit au lecteur (épisode suivant, relance) : celui-ci s'y
/// accroche en s'ouvrant et s'en détache en se fermant. Voir
/// [WatchPartySession].
class PlayerWatchParty extends ChangeNotifier {
  PlayerWatchParty({
    required this.controller,
    required this.api,
    required this.accountKey,
    required this.mediaId,
    required this.isGone,
    required this.playbackRate,
    required this.setWantsPlayback,
    required this.openMedia,
  });

  final PlayerController controller;
  final ApiClient? Function() api;

  /// Le serveur qui héberge une séance ouverte d'ici.
  final String Function() accountKey;
  final int Function() mediaId;

  /// Le lecteur s'en va, se démonte, ou n'est plus monté.
  final bool Function() isGone;

  /// La vitesse choisie par la personne devant l'écran.
  final double Function() playbackRate;
  final void Function(bool wanted) setWantsPlayback;

  /// La séance est passée à un autre média : le lecteur l'ouvre.
  final void Function(HomeMediaItem media,
      {required int resumeAtSeconds, required bool startPaused}) openMedia;

  /// La séance à laquelle ce lecteur est accroché, s'il y en a une.
  WatchPartySession? party;
  late final _WatchPartyBinding _binding = _WatchPartyBinding(this);
  StreamSubscription<String>? _notices;
  String? notice;
  bool noticeVisible = false;
  Timer? _noticeTimer;

  /// Jusqu'à quand un recalage demandé par la séance est en train de se poser.
  DateTime? _seekSettlesAt;

  /// Le facteur que la séance applique à la vitesse choisie, pour rattraper
  /// un petit écart sans couper. 1 hors séance.
  double rateFactor = 1;

  /// Ce lecteur cède la place à un autre (épisode suivant, relance) : la
  /// séance continue avec lui, elle ne doit pas être quittée ici.
  bool handOver = false;

  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void listen() {
    WatchPartySession.active.addListener(sync);
  }

  /// Accroche ce lecteur à la séance active, si elle le concerne.
  void sync() {
    final next = WatchPartySession.active.value;
    final eligible = next != null &&
        !next.isClosed &&
        api() != null &&
        next.accountId == accountKey();
    final target = eligible ? next : null;
    if (identical(target, party)) return;
    party?.detach(_binding);
    party?.removeListener(_notify);
    party = target;
    if (target != null) {
      // La séance a changé (participants, attente) : le bouton et le message
      // « En attente de… » suivent.
      target.addListener(_notify);
      // L'abonnement précédent n'est coupé qu'ici, pas à la fin de la séance :
      // son dernier message (« La séance est terminée ») arrive après.
      unawaited(_notices?.cancel());
      _notices = target.notices.listen(showNotice);
      target.attach(_binding);
    }
    _notify();
  }

  void showNotice(String text) {
    _noticeTimer?.cancel();
    notice = text;
    noticeVisible = true;
    _notify();
    _noticeTimer = Timer(const Duration(seconds: 3), () {
      noticeVisible = false;
      _notify();
    });
  }

  Future<void> start() async {
    final client = api();
    if (client == null) {
      throw StateError('Aucun serveur pour héberger la séance');
    }
    await WatchPartySession.create(
      api: client,
      accountId: accountKey(),
      mediaId: mediaId(),
      position: controller.position,
      playing: controller.isPlaying,
    );
  }

  /// Quitter de soi-même : les autres continuent.
  void leave({required String notice}) {
    final current = party;
    if (current == null) return;
    unawaited(current.leave());
    showNotice(notice);
  }

  /// Le lecteur passe à un autre épisode. La séance passe avec lui — sauf si
  /// c'est elle qui l'a demandé, auquel cas elle y est déjà.
  ///
  /// Returns whether there was a session to carry along.
  bool carryTo(int nextMediaId, {required bool fromParty}) {
    final current = party;
    if (current == null) return false;
    handOver = true;
    current.detach(_binding);
    if (!fromParty) unawaited(current.sendMedia(nextMediaId));
    return true;
  }

  /// Quitter le lecteur, c'est quitter la séance — sauf pour la passer au
  /// lecteur suivant.
  void leaveWithPlayer() {
    final current = party;
    if (current != null && !handOver) unawaited(current.leave());
  }

  @override
  void dispose() {
    _disposed = true;
    WatchPartySession.active.removeListener(sync);
    final current = party;
    if (current != null) {
      current.removeListener(_notify);
      current.detach(_binding);
      if (!handOver) unawaited(current.leave());
    }
    unawaited(_notices?.cancel() ?? Future<void>.value());
    _noticeTimer?.cancel();
    super.dispose();
  }
}

/// Le lecteur, tel que la séance le voit. Tout ce qui arrive par ici vient
/// des autres appareils et ne repart donc pas : voir [WatchPartyPlayer].
class _WatchPartyBinding implements WatchPartyPlayer {
  _WatchPartyBinding(this._link);

  final PlayerWatchParty _link;
  PlayerController get _controller => _link.controller;

  @override
  int get mediaId => _link.mediaId();

  @override
  bool get isReady => _controller.hasFirstFrame && !_link.isGone();

  @override
  bool get isLoading =>
      !_controller.hasFirstFrame ||
      _controller.isBuffering ||
      _controller.isSwitchingQuality;

  @override
  bool get isBusy {
    final settles = _link._seekSettlesAt;
    return _controller.isBuffering ||
        _controller.isSwitchingQuality ||
        (settles != null && DateTime.now().isBefore(settles));
  }

  @override
  bool get isPlaying => _controller.isPlaying;

  @override
  Duration get position => _controller.position;

  @override
  Future<void> applyPlaying(bool playing) async {
    if (_controller.isPlaying == playing) return;
    _link.setWantsPlayback(playing);
    _controller.togglePlayPause();
    _link._notify();
  }

  @override
  Future<void> applySeek(Duration position) async {
    // Le temps que la position rapportée par le moteur rejoigne la cible.
    _link._seekSettlesAt =
        DateTime.now().add(const Duration(milliseconds: 1200));
    await _controller.seekToAbsolutePosition(position);
  }

  @override
  Future<void> applyRateFactor(double factor) async {
    _link.rateFactor = factor;
    await _controller.session.setRate(_link.playbackRate() * factor);
  }

  @override
  void openMedia(HomeMediaItem media, Duration position,
      {required bool playing}) {
    if (_link.isGone()) return;
    _link.openMedia(
      media,
      resumeAtSeconds: position.inSeconds,
      startPaused: !playing,
    );
  }
}
