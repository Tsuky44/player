import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/download_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Un client dont l'adresse se déplace, comme le fait une bascule de serveur.
class _MovableApi extends ApiClient {
  _MovableApi(this._url);

  String _url;
  set url(String value) => _url = value;

  @override
  String get baseUrl => _url;
}

class _TempSupportDirectory extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TempSupportDirectory(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

Map<String, dynamic> _entry({
  required int mediaId,
  required String title,
  required String serverUrl,
}) {
  return {
    'media_id': mediaId,
    'type': 'movie',
    'title': title,
    'file_name': 'video.mkv',
    'added_at': '2026-09-01T12:00:00.000Z',
    'server_url': serverUrl,
    'duration': 2400,
    'status': 'completed',
    'bytes_received': 1000,
    'bytes_total': 1000,
    'needs_sync': false,
  };
}

/// Le `media_id` est un numéro **propre à un serveur** : le film 1 de l'un n'a
/// rien à voir avec le film 1 de l'autre. Depuis qu'un appareil peut tenir
/// plusieurs serveurs (ADR-0013), la liste en mémoire est donc celle du serveur
/// actif — sans quoi deux bibliothèques se recouvriraient à la première
/// collision de numéro. Le manifeste, lui, continue de tout porter.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _MovableApi api;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('onyx_scope_test');
    PathProviderPlatform.instance = _TempSupportDirectory(root.path);

    final store = Directory('${root.path}/onyx_offline')
      ..createSync(recursive: true);
    File('${store.path}/manifest.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'items': [
        _entry(mediaId: 1, title: 'À la maison', serverUrl: 'http://maison:8080'),
        // Même numéro, autre serveur : c'est exactement le cas qui casserait
        // une carte indexée sur le seul media_id.
        _entry(mediaId: 1, title: 'Chez Paul', serverUrl: 'http://paul:8080'),
        _entry(mediaId: 2, title: 'Aussi chez Paul', serverUrl: 'http://paul:8080'),
      ],
    }));

    api = _MovableApi('http://maison:8080');
    await DownloadManager.instance.initialize(api);
  });

  tearDownAll(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('seul le serveur actif est listé', () {
    final manager = DownloadManager.instance;
    expect(manager.downloads, hasLength(1));
    expect(manager.entryFor(1)?.title, 'À la maison');
  });

  test('basculer montre la bibliothèque de l’autre serveur', () async {
    final manager = DownloadManager.instance;
    api.url = 'http://paul:8080';
    await manager.onServerChanged();

    expect(manager.downloads, hasLength(2));
    expect(manager.entryFor(1)?.title, 'Chez Paul',
        reason: 'le film 1 n’est pas le même des deux côtés');
    expect(manager.entryFor(2)?.title, 'Aussi chez Paul');
  });

  test('ce qui appartient à l’autre serveur n’est pas perdu en route', () async {
    final manager = DownloadManager.instance;
    // Une écriture du manifeste depuis « paul » ne doit pas effacer « maison ».
    await manager.delete(2);

    final raw = jsonDecode(
      File('${root.path}/onyx_offline/manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final titles =
        (raw['items'] as List).map((e) => e['title'] as String).toList();

    expect(titles, contains('À la maison'));
    expect(titles, contains('Chez Paul'));
    expect(titles, isNot(contains('Aussi chez Paul')));

    // Et le retour sur « maison » retrouve bien son film.
    api.url = 'http://maison:8080';
    await manager.onServerChanged();
    expect(manager.entryFor(1)?.title, 'À la maison');
  });
}
