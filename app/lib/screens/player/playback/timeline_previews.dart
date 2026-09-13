import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// How the server spaced a file's stills: still `i` shows second
/// `i * interval`.
@immutable
class TimelinePreviewManifest {
  final int interval;
  final int count;
  final int width;
  final int height;

  const TimelinePreviewManifest({
    required this.interval,
    required this.count,
    required this.width,
    required this.height,
  });

  factory TimelinePreviewManifest.fromJson(Map<String, dynamic> json) =>
      TimelinePreviewManifest(
        interval: (json['interval'] as num?)?.toInt() ?? 0,
        count: (json['count'] as num?)?.toInt() ?? 0,
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
      );

  bool get isUsable => interval > 0 && count > 0;

  double get aspectRatio =>
      width > 0 && height > 0 ? width / height : 16 / 9;

  /// The still closest to [position]. Rounded rather than floored: a still is
  /// the keyframe at or before its second, so flooring would show a picture
  /// up to two intervals behind the pointer.
  int indexFor(Duration position) {
    if (!isUsable) return 0;
    final index = (position.inMilliseconds / (interval * 1000)).round();
    return index.clamp(0, count - 1);
  }
}

/// The stills shown above the scrubber, fetched as the pointer asks for them.
///
/// Only started once the first frame is on screen — see
/// [PlayerController] — so none of it competes with the start of playback.
/// From then on the server fills the timeline in the background, and a hover
/// the background pass has not reached yet is extracted on the spot (a single
/// keyframe, tens of milliseconds).
///
/// What keeps a scrub responsive on this side:
///   - one fetch at a time, always for the latest position asked, so a fast
///     sweep across the bar never queues up every still it crossed;
///   - the nearest still already in memory stands in while the exact one
///     loads, so the box never goes blank mid-scrub;
///   - once the pointer settles, the neighbours are fetched too, which is
///     where it goes next.
class TimelinePreviews extends ChangeNotifier {
  TimelinePreviews({
    required Future<Map<String, dynamic>> Function() open,
    required Future<Uint8List> Function(int index) fetch,
    this.cacheSize = 240,
  })  : _open = open,
        _fetch = fetch;

  final Future<Map<String, dynamic>> Function() _open;
  final Future<Uint8List> Function(int index) _fetch;

  /// Stills kept decoded-ready in memory. At ~20 KB each this is a few MB.
  final int cacheSize;

  static const _neighbourSpan = 2;
  static const _maxConsecutiveFailures = 4;

  TimelinePreviewManifest? _manifest;
  final LinkedHashMap<int, ImageProvider> _cache = LinkedHashMap();
  final Set<int> _failed = {};
  int? _wanted;
  bool _fetching = false;
  bool _started = false;
  bool _disposed = false;
  bool _broken = false;
  int _failures = 0;

  /// Null until the server has answered, and for good if it could not.
  TimelinePreviewManifest? get manifest => _broken ? null : _manifest;

  bool get isReady => manifest != null;

  /// Asks the server for the manifest, which also starts its background pass.
  /// Safe to call more than once; failures leave the bar without stills.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    try {
      final manifest = TimelinePreviewManifest.fromJson(await _open());
      if (_disposed || !manifest.isUsable) return;
      _manifest = manifest;
      notifyListeners();
    } catch (e) {
      debugPrint('TimelinePreviews: unavailable (${e.runtimeType})');
    }
  }

  /// The still for [index] if it is in memory, otherwise the nearest one that
  /// is, otherwise null.
  ImageProvider? imageFor(int index) {
    final exact = _cache[index];
    if (exact != null) return exact;
    int? best;
    for (final key in _cache.keys) {
      if (best == null || (key - index).abs() < (best - index).abs()) {
        best = key;
      }
    }
    return best == null ? null : _cache[best];
  }

  bool hasExact(int index) => _cache.containsKey(index);

  /// Records that the pointer is over [index]. Never notifies synchronously,
  /// so it is safe to call from a build method.
  void request(int index) {
    final manifest = this.manifest;
    if (manifest == null || _disposed) return;
    final clamped = index.clamp(0, manifest.count - 1);
    if (_wanted == clamped) return;
    _wanted = clamped;
    if (!_fetching) unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_fetching) return;
    _fetching = true;
    try {
      while (!_disposed && !_broken) {
        final next = _nextIndex();
        if (next == null) break;
        await _load(next);
      }
    } finally {
      _fetching = false;
    }
  }

  /// The latest position first; its neighbours only once it is satisfied.
  int? _nextIndex() {
    final wanted = _wanted;
    final manifest = _manifest;
    if (wanted == null || manifest == null) return null;
    if (_needs(wanted)) return wanted;
    for (var d = 1; d <= _neighbourSpan; d++) {
      for (final i in [wanted + d, wanted - d]) {
        if (i >= 0 && i < manifest.count && _needs(i)) return i;
      }
    }
    return null;
  }

  bool _needs(int index) =>
      !_cache.containsKey(index) && !_failed.contains(index);

  Future<void> _load(int index) async {
    try {
      final bytes = await _fetch(index);
      if (_disposed) return;
      _failures = 0;
      _cache.remove(index);
      _cache[index] = MemoryImage(bytes);
      while (_cache.length > cacheSize) {
        _cache.remove(_cache.keys.first);
      }
      notifyListeners();
    } catch (e) {
      if (_disposed) return;
      _failed.add(index);
      _failures++;
      if (_failures >= _maxConsecutiveFailures) {
        // Server without the endpoint, expired ticket, broken file: stop
        // asking rather than fail on every movement of the mouse.
        debugPrint('TimelinePreviews: disabled after repeated failures '
            '(${e.runtimeType})');
        _broken = true;
        notifyListeners();
      }
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cache.clear();
    super.dispose();
  }
}
