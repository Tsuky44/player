import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../utils/app_platform.dart';
import 'caches_directory_repository.dart';

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

  // Artwork is immutable per id; the only reason to expire is disk hygiene.
  static const Duration _stalePeriod = Duration(days: 60);
  static const int _maxObjects = 3000;

  static final CacheManager manager = CacheManager(_config());

  /// L'Apple TV n'a pas d'Application Support, où le paquet range son index :
  /// sans son propre dépôt, aucune image ne s'y affichait. Ailleurs, `repo`
  /// reste omis (le paramètre n'accepte pas null) et le paquet garde le sien.
  static Config _config() {
    final repo = imageCacheRepository(cacheKey);
    if (repo == null) {
      return Config(
        cacheKey,
        stalePeriod: _stalePeriod,
        maxNrOfCacheObjects: _maxObjects,
      );
    }
    return Config(
      cacheKey,
      stalePeriod: _stalePeriod,
      maxNrOfCacheObjects: _maxObjects,
      repo: repo,
    );
  }

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
  /// mobile and the Apple TV keep Flutter's defaults.
  static void configure() {
    if (AppPlatform.isMobile || AppPlatform.isTvOS) return;
    PaintingBinding.instance.imageCache
      ..maximumSizeBytes = 300 << 20
      ..maximumSize = 2000;
  }
}
