import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/app_download.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/update_checker.dart';
import 'package:onyx/utils/store_build.dart';

class _CountingApi extends ApiClient {
  int calls = 0;

  @override
  Future<List<AppDownload>> getAppDownloads() async {
    calls++;
    return const [];
  }
}

void main() {
  tearDown(() => StoreBuild.overrideForTest(null));

  test('un build store ne cherche jamais de mise à jour sur le serveur',
      () async {
    StoreBuild.overrideForTest(true);
    final api = _CountingApi();

    expect(await UpdateChecker.findAvailableUpdate(api), isNull);
    expect(api.calls, 0,
        reason: 'un magasin interdit la mise à jour hors de chez lui : le '
            'serveur ne doit même pas être interrogé');
  });

  test('hors build store, le serveur est interrogé', () async {
    StoreBuild.overrideForTest(false);
    final api = _CountingApi();

    await UpdateChecker.findAvailableUpdate(api);
    expect(api.calls, 1);
  });

  // Un second `fromEnvironment('STORE_BUILD')` ailleurs échapperait à
  // `overrideForTest`, et rien ne garantirait plus que les deux lectures
  // disent la même chose.
  test('STORE_BUILD ne se lit que dans store_build.dart', () {
    final offenders = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.uri.path.endsWith('utils/store_build.dart'))
        .where((f) => f.readAsStringSync().contains("'STORE_BUILD'"))
        .map((f) => f.path)
        .toList();
    expect(offenders, isEmpty,
        reason: 'passe par StoreBuild.enabled, le seul point de lecture');
  });
}
