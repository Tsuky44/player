import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/progress_sync.dart';
import 'package:onyx/services/server_registry.dart';
import 'progress_sync_test.dart' show Adapter;

class SlowSync extends ProgressSync {
  SlowSync(super.servers);
  final done = Completer<void>();
  @override
  Future<void> synchronize(
          {bool force = false, String? sourceAccountId, int? mediaId}) =>
      done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('server selection and catalog do not wait for an unavailable sync peer',
      () async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => null);
    final registry = ServerRegistry();
    await registry.load();
    final a = await registry.remember(
        url: 'http://a.test', username: 'a', token: 'a');
    await registry.remember(url: 'http://b.test', username: 'b', token: 'b');
    final slow = SlowSync(registry);
    final dio = Dio()
      ..httpClientAdapter = Adapter((r) => ResponseBody.fromString(
              r.path == '/api/home'
                  ? '{}'
                  : '[{"id":1,"type":"movie","title":"A"}]',
              200,
              headers: {
                Headers.contentTypeHeader: [Headers.jsonContentType]
              }));
    final api =
        ApiClient(registry: registry, httpClient: dio, progressSync: slow);
    await api.initialize();
    var refreshed = 0;
    api.onProgressSynchronized = () => refreshed++;
    try {
      expect(
          await api.activateAccount(a.id).timeout(const Duration(seconds: 1)),
          true);
      expect(
          (await api.getMovies().timeout(const Duration(seconds: 1)))
              .single
              .media
              .title,
          'A');
      await api.getHome().timeout(const Duration(seconds: 1));
      expect(slow.done.isCompleted, false);
    } finally {
      slow.done.complete();
    }
    await Future<void>.delayed(Duration.zero);
    expect(refreshed, 1);
  });
}
