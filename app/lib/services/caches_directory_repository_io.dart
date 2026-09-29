import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/app_platform.dart';

/// Le dépôt à donner à la configuration du cache d'images : le nôtre sur
/// l'Apple TV, celui du paquet (null) partout ailleurs, pour ne pas déplacer
/// les caches déjà remplis des autres appareils.
CacheInfoRepository? imageCacheRepository(String cacheKey) =>
    AppPlatform.isTvOS ? CachesDirectoryRepository(cacheKey) : null;

/// L'index du cache d'images rangé dans `Library/Caches`, pour l'Apple TV.
///
/// Sur un appareil Apple, `flutter_cache_manager` range son index SQLite dans
/// Application Support. Sur une vraie Apple TV, ce dossier n'existe pas et ne
/// peut pas être créé : seuls `Library/Caches` et `tmp` s'écrivent (mesuré par
/// l'auteur de `path_provider_tvos`, qui renvoie alors null). Le moteur tvOS
/// répondant `true` à `Platform.isIOS`, le paquet prenait ce chemin, l'ouverture
/// de l'index échouait, et chaque image restait sur son espace réservé sans
/// jamais lever d'erreur : `CacheStore` attend l'index sans traiter son échec.
/// Le simulateur accepte l'écriture, d'où une panne visible sur l'appareil
/// seulement. Voir ADR-0028.
///
/// Le chemin ne se connaît qu'après un appel à la plateforme, alors que le
/// dépôt se construit avec le gestionnaire, au chargement de la classe : il est
/// donc résolu à la première ouverture, puis tout est délégué au dépôt SQLite
/// ordinaire.
class CachesDirectoryRepository extends CacheInfoRepository {
  CachesDirectoryRepository(
    this.databaseName, {
    Future<Directory> Function()? directory,
    CacheInfoRepository Function(String path)? repositoryAt,
  })  : _directory = directory ?? getApplicationCacheDirectory,
        _repositoryAt =
            repositoryAt ?? ((path) => CacheObjectProvider(path: path));

  final String databaseName;
  final Future<Directory> Function() _directory;
  final CacheInfoRepository Function(String path) _repositoryAt;

  Future<CacheInfoRepository>? _inner;

  Future<CacheInfoRepository> get _repo => _inner ??= () async {
        final dir = await _directory();
        return _repositoryAt(p.join(dir.path, '$databaseName.db'));
      }();

  @override
  Future<bool> exists() async => (await _repo).exists();

  @override
  Future<bool> open() async => (await _repo).open();

  @override
  Future<dynamic> updateOrInsert(CacheObject cacheObject) async =>
      (await _repo).updateOrInsert(cacheObject);

  @override
  Future<CacheObject> insert(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) async =>
      (await _repo).insert(cacheObject, setTouchedToNow: setTouchedToNow);

  @override
  Future<CacheObject?> get(String key) async => (await _repo).get(key);

  @override
  Future<int> delete(int id) async => (await _repo).delete(id);

  @override
  Future<int> deleteAll(Iterable<int> ids) async =>
      (await _repo).deleteAll(ids);

  @override
  Future<int> update(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) async =>
      (await _repo).update(cacheObject, setTouchedToNow: setTouchedToNow);

  @override
  Future<List<CacheObject>> getAllObjects() async =>
      (await _repo).getAllObjects();

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) async =>
      (await _repo).getObjectsOverCapacity(capacity);

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) async =>
      (await _repo).getOldObjects(maxAge);

  @override
  Future<bool> close() async => (await _repo).close();

  @override
  Future<void> deleteDataFile() async => (await _repo).deleteDataFile();
}
