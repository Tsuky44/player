import 'dart:async';

/// One independent authorization lease per player/download. Never persisted.
/// A lease retains its source origin even when the active account changes.
class PlaybackAccess {
  PlaybackAccess({
    required this.origin,
    required this.mediaId,
    required String? token,
    required DateTime? expiresAt,
    required Future<DateTime> Function() renew,
    required Future<void> Function() revoke,
    Duration renewEvery = const Duration(minutes: 5),
  })  : _token = token,
        _expiresAt = expiresAt,
        _renew = renew,
        _revoke = revoke {
    if (token != null) {
      _timer = Timer.periodic(renewEvery, (_) => unawaited(_refresh()));
    }
  }

  final String origin;
  final int mediaId;
  final String? _token;
  DateTime? _expiresAt;
  final Future<DateTime> Function() _renew;
  final Future<void> Function() _revoke;
  Timer? _timer;
  bool _closed = false;
  bool _refreshing = false;
  bool get isLegacy => _token == null;

  Map<String, String> get query {
    if (_closed ||
        (_expiresAt != null && !DateTime.now().isBefore(_expiresAt!))) {
      throw StateError('Autorisation de lecture expirée. Relancez la lecture.');
    }
    return _token == null ? const {} : {'ticket': _token!};
  }

  String protect(String url) {
    final uri = Uri.parse(url);
    if (uri.origin != Uri.parse(origin).origin) {
      throw StateError(
          'Une autorisation de lecture ne peut pas changer de serveur.');
    }
    return uri.replace(
        queryParameters: {...uri.queryParameters, ...query}).toString();
  }

  Future<void> _refresh() async {
    if (_closed || _refreshing) return;
    _refreshing = true;
    try {
      final deadline = await _renew();
      if (!_closed) _expiresAt = deadline;
    } catch (_) {
      // The current deadline is unchanged. A network failure must never cause
      // a downgrade to a public URL; the next interval can retry renewal.
    } finally {
      _refreshing = false;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    if (_token != null) {
      try {
        await _revoke();
      } catch (_) {/* Server expiry is the fallback. */}
    }
  }

  @override
  String toString() => 'PlaybackAccess(protected)';
}

/// Diagnostics may contain engine/Dio exceptions with nested URLs. Remove the
/// entire URL, not just a known token parameter, before sharing or logging.
String redactPlaybackDiagnostic(Object? value) => (value?.toString() ?? '')
    .replaceAll(RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false),
        '[URL masquée]')
    .replaceAll(RegExp(r'\bBearer\s+[^\s,"\x27}]+', caseSensitive: false),
        'Bearer [masqué]')
    .replaceAllMapped(
        RegExp(
            r'''["']?(ticket|token|authorization)["']?\s*[=:]\s*["']?[^\s&,"'}]+''',
            caseSensitive: false),
        (match) => '${match[1]}=[masqué]');
