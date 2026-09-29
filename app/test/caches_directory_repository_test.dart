import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/caches_directory_repository_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Le bac à sable d'une vraie Apple TV, tel que `path_provider_tvos` le
/// rapporte : pas d'Application Support, un dossier Caches.
class _AppleTvSandbox extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _AppleTvSandbox(this.caches);

  final String caches;

  @override
  Future<String?> getApplicationSupportPath() async => null;

  @override
  Future<String?> getApplicationCachePath() async => caches;
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('onyx_caches_repo_');
    PathProviderPlatform.instance = _AppleTvSandbox(root.path);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
      "l'index du cache d'images s'ouvre et s'écrit sans Application Support "
      '(Apple TV)', () async {
    String? openedAt;
    // Le dépôt JSON remplace SQLite, absent des tests : ce qui est vérifié,
    // c'est l'endroit où l'index se range, pas son format.
    final repo = CachesDirectoryRepository(
      'onyxImageCache',
      repositoryAt: (path) {
        openedAt = path;
        return JsonCacheInfoRepository(path: p.setExtension(path, '.json'));
      },
    );

    expect(await repo.open(), isTrue);
    await repo.insert(CacheObject(
      'https://image.tmdb.org/t/p/w1280/fond.jpg',
      relativePath: 'fond.file',
      validTill: DateTime.now().add(const Duration(days: 1)),
    ));

    expect(openedAt, p.join(root.path, 'onyxImageCache.db'));
    final stored =
        await repo.get('https://image.tmdb.org/t/p/w1280/fond.jpg');
    expect(stored?.relativePath, 'fond.file');
    await repo.close();
  });
}
