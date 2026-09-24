import 'dart:async';

import '../models/app_download.dart';
import 'player_presence.dart';

/// Polls the server for a newer build and hands it to [onUpdateFound] once,
/// per version, so the app updates itself without anyone having to notice the
/// header button.
///
/// Kept separate from `UpdateChecker` because that one just answers a
/// question ("is there an update"); this one decides *when* to ask it and
/// remembers what it already surfaced.
class AutoUpdateService {
  /// `UpdateChecker.findAvailableUpdate` en production ; une doublure en test.
  final Future<AppDownload?> Function() findUpdate;
  final void Function(AppDownload download) onUpdateFound;

  /// Vrai pendant qu'un film tourne. Une mise à jour trouvée à ce moment-là
  /// attend le prochain démarrage : le dialogue, son téléchargement et son
  /// redémarrage automatique couperaient la lecture.
  final bool Function() isPlaying;

  /// First check, run once the app has settled rather than racing the home
  /// screen's own startup requests.
  final Duration initialDelay;

  /// How often to look again while the app stays open — long enough that it
  /// never feels like polling, short enough that a server publishing a fix
  /// reaches a long-running session the same day.
  final Duration interval;

  Timer? _initialTimer;
  Timer? _periodicTimer;
  bool _checking = false;
  String? _lastHandledVersion;

  AutoUpdateService({
    required this.findUpdate,
    required this.onUpdateFound,
    this.isPlaying = PlayerPresence.isOpen,
    this.initialDelay = const Duration(seconds: 5),
    this.interval = const Duration(minutes: 30),
  });

  void start() {
    _initialTimer = Timer(initialDelay, () {
      unawaited(_check());
      _periodicTimer = Timer.periodic(interval, (_) => unawaited(_check()));
    });
  }

  void dispose() {
    _initialTimer?.cancel();
    _periodicTimer?.cancel();
  }

  Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    try {
      final update = await findUpdate();
      if (update == null || update.version == _lastHandledVersion) return;
      if (isPlaying()) {
        // Reportée au prochain démarrage, dont la première vérification la
        // retrouvera : plus rien ne s'affiche dans cette session, pas même
        // à la fin du film.
        dispose();
        return;
      }
      _lastHandledVersion = update.version;
      onUpdateFound(update);
    } finally {
      _checking = false;
    }
  }
}
