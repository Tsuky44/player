import 'dart:async';

import '../models/app_download.dart';
import 'api_client.dart';
import 'update_checker.dart';

/// Polls the server for a newer build and hands it to [onUpdateFound] once,
/// per version, so the app updates itself without anyone having to notice the
/// header button.
///
/// Kept separate from [UpdateChecker] because that one just answers a
/// question ("is there an update"); this one decides *when* to ask it and
/// remembers what it already surfaced.
class AutoUpdateService {
  final ApiClient api;
  final void Function(AppDownload download) onUpdateFound;

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
    required this.api,
    required this.onUpdateFound,
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
      final update = await UpdateChecker.findAvailableUpdate(api);
      if (update == null || update.version == _lastHandledVersion) return;
      _lastHandledVersion = update.version;
      onUpdateFound(update);
    } finally {
      _checking = false;
    }
  }
}
