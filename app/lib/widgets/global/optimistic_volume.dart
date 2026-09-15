/// What a volume slider shows while the engine catches up with it.
///
/// The engine's volume is not a stream: a slider that draws it can only move
/// when something else rebuilds the player — the position tick, a few times a
/// second while playing, and never while paused. Dragging it looked like two
/// frames a second. The slider shows what the user asked for instead, and hands
/// back to the engine once the engine agrees, or once the volume changes from
/// somewhere else (a key, a remote).
class OptimisticVolume {
  /// How long after the last user change a differing engine value is taken for
  /// the engine lagging rather than for someone else changing the volume.
  static const Duration _settle = Duration(milliseconds: 600);

  double? _requested;
  double? _lastReported;
  DateTime _requestedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Records a value the user just picked. Call inside `setState`.
  void request(double volume) {
    _requested = volume.clamp(0.0, 100.0);
    _requestedAt = DateTime.now();
  }

  /// The value to draw, given what the engine currently reports.
  double resolve(double? reported) {
    final requested = _requested;
    if (requested != null && reported != null) {
      final agrees = (reported - requested).abs() < 0.5;
      final changedElsewhere = _lastReported != null &&
          reported != _lastReported &&
          DateTime.now().difference(_requestedAt) > _settle;
      if (agrees || changedElsewhere) _requested = null;
    }
    _lastReported = reported;
    return (_requested ?? reported ?? 50.0).clamp(0.0, 100.0);
  }
}
