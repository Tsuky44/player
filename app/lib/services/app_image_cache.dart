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

  static final CacheManager manager = _IndexedCacheManager(_config());

  /// Les URL dont les octets sont sur disque, lisibles sans attendre.
  ///
  /// Une image déjà téléchargée s'affiche en quelques millisecondes (lecture du
  /// fichier, décodage hors du fil principal), mais `CachedNetworkImage` la
  /// fait quand même apparaître en fondu de 180 ms : elle semblait arriver du
  /// réseau à chaque ouverture de l'app. Savoir *avant* de construire le widget
  /// que l'image est là permet de la poser sans fondu (ADR-0088).
  ///
  /// Le nettoyage par capacité du paquet ne passe pas par ici : une entrée
  /// peut survivre à son fichier. Le seul effet est une image réseau qui
  /// arrive sans fondu, jamais une image manquante.
  static final Set<String> _onDisk = <String>{};

  /// Vrai quand les octets de [url] sont sur disque.
  static bool isOnDisk(String url) => _onDisk.contains(url);

  @visibleForTesting
  static void markOnDiskForTest(String url) => _onDisk.add(url);

  @visibleForTesting
  static void resetOnDiskForTest() => _onDisk.clear();

  /// Charge l'index du cache disque en mémoire, une requête au démarrage.
  ///
  /// Appelé sans attendre : la première image ne patiente pas derrière lui, et
  /// une image demandée avant la fin garde simplement son fondu.
  static Future<void> loadDiskIndex() async {
    if (kIsWeb) return;
    try {
      final repo = manager.config.repo;
      // `open` est partagé : c'est la même ouverture que celle du dépôt.
      await repo.open();
      for (final object in await repo.getAllObjects()) {
        _onDisk.add(object.key);
      }
    } catch (error) {
      // Sans index, les images s'affichent comme avant, en fondu : rien ne
      // casse, on le note seulement.
      debugPrint('AppImageCache: index disque illisible: $error');
    }
  }

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
  ///
  /// En mode léger (ADR-0086), le plafond descend sous celui de Flutter : sur
  /// une Apple TV HD ou un boîtier à 2 Go, les 100 Mo d'images décodées
  /// disputent la mémoire au décodeur vidéo, et c'est le film qui saccade. Une
  /// affiche redécodée au retour coûte un éclair de vignette, pas une image
  /// perdue.
  static void configure({bool lite = false}) {
    if (lite) {
      PaintingBinding.instance.imageCache
        ..maximumSizeBytes = 48 << 20
        ..maximumSize = 400;
      return;
    }
    if (AppPlatform.isMobile || AppPlatform.isTvOS) return;
    PaintingBinding.instance.imageCache
      ..maximumSizeBytes = 300 << 20
      ..maximumSize = 2000;
  }
}

/// Le gestionnaire du cache, qui tient [AppImageCache._onDisk] à jour à
/// chaque fichier servi ou retiré.
class _IndexedCacheManager extends CacheManager {
  _IndexedCacheManager(super.config);

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    final cacheKey = key ?? url;
    return super
        .getFileStream(
      url,
      key: key,
      headers: headers,
      withProgress: withProgress,
    )
        .map((response) {
      if (response is FileInfo) AppImageCache._onDisk.add(cacheKey);
      return response;
    });
  }

  @override
  Future<void> removeFile(String key) async {
    AppImageCache._onDisk.remove(key);
    await super.removeFile(key);
  }

  @override
  Future<void> emptyCache() async {
    AppImageCache._onDisk.clear();
    await super.emptyCache();
  }
}
