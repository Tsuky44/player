import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../utils/app_platform.dart';

/// The single on-disk store behind every remote image the app renders.
///
/// Left to itself `cached_network_image` uses [DefaultCacheManager], which
/// keeps **200 files**. A catalog grid plus one detail page (poster, backdrop,
/// logo, a dozen headshots) already blows past that, so artwork was being
/// evicted and re-downloaded on the way back to a screen that had just drawn
/// it — the "images that reload every time" symptom. Artwork for a given TMDB
/// id never changes, so a much larger, longer-lived store is the right trade:
/// a few tens of MB of disk against a network round trip per image.
///
/// Web never reaches this. `CachedNetworkImage` renders through an `<img>` tag
/// there and the browser's own HTTP cache does the same job.
class AppImageCache {
  AppImageCache._();

  /// Namespaced so a change of policy here cannot collide with the default
  /// store another package might be using.
  static const String cacheKey = 'onyxImageCache';

  static final CacheManager manager = CacheManager(
    Config(
      cacheKey,
      // Artwork is immutable per id; the only reason to expire is disk hygiene.
      stalePeriod: const Duration(days: 60),
      maxNrOfCacheObjects: 3000,
    ),
  );

  /// The manager to hand to `CachedNetworkImage`.
  ///
  /// Null on web, where the widget ignores it anyway — passing a manager there
  /// would only build a memory-backed store that duplicates the browser cache.
  static CacheManager? get imageCacheManager => kIsWeb ? null : manager;

  /// Widens Flutter's decoded-image cache.
  ///
  /// The default ceiling is 100 MB / 1000 entries. Scrolling a grid of posters
  /// and then opening a detail page evicts the grid, so scrolling back decoded
  /// every poster again — visible as a flash of placeholder on content that was
  /// on screen a second earlier. Desktop and web have the headroom to hold it;
  /// mobile keeps Flutter's defaults.
  static void configure() {
    if (AppPlatform.isMobile) return;
    PaintingBinding.instance.imageCache
      ..maximumSizeBytes = 300 << 20
      ..maximumSize = 2000;
  }
}
