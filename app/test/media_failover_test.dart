import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/services/media_failover.dart';
import 'progress_sync_test.dart' show Registry, Adapter;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
      'cached episode identity resolves a different local ID after source failure',
      () async {
    final registry = Registry();
    var sourceDown = false;
    var missing = false;
    final requests = <String>[];
    Dio client(BaseOptions options) {
      final dio = Dio(options);
      dio.httpClientAdapter = Adapter((r) {
        requests.add('${r.uri.host}${r.path}');
        final source = r.uri.host == 'a.test';
        expect(r.headers['Authorization'],
            source ? 'Bearer token-a' : 'Bearer token-b');
        if (source && sourceDown)
          throw DioException(
              requestOptions: r, type: DioExceptionType.connectionError);
        dynamic body = {};
        if (r.path == '/api/media-identities') {
          body = {
            '7': {
              'type': 'episode',
              'tmdb_id': 42,
              'season_number': 1,
              'episode_number': 5
            }
          };
        } else if (r.path == '/api/media-resolve') {
          expect(r.data['tmdb_id'], 42);
          expect(r.data['episode_number'], 5);
          if (missing) return ResponseBody.fromString('missing', 404);
          body = {
            'id': 99,
            'type': 'episode',
            'title': 'Copy',
            'duration': 1800,
            'current_position_seconds': 120,
            'is_finished': false
          };
        }
        return ResponseBody.fromString(jsonEncode(body), 200, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        });
      });
      return dio;
    }

    final media = Media(
        id: 7,
        type: MediaType.episode,
        title: 'Episode',
        duration: 1800,
        createdAt: DateTime(2020));
    final service = MediaFailover(registry, clientFactory: client);
    await service.refreshIdentities('a');
    expect(await service.findReplacement(sourceAccountId: 'a', media: media),
        isNull);
    sourceDown = true;
    // A fresh service must work from the persisted identity, without source metadata.
    final restarted = MediaFailover(registry, clientFactory: client);
    final relay =
        await restarted.findReplacement(sourceAccountId: 'a', media: media);
    expect(relay?.account.id, 'b');
    expect(relay?.media.id, 99);
    expect(relay?.resumeAtSeconds, 120);
    missing = true;
    expect(await restarted.findReplacement(sourceAccountId: 'a', media: media),
        isNull);
    missing = false;
    expect(
        await restarted.findReplacement(
            sourceAccountId: 'a', media: media, excluded: {'b'}),
        isNull);
    registry.linked = false;
    requests.clear();
    expect(await restarted.findReplacement(sourceAccountId: 'a', media: media),
        isNull);
    expect(requests, isEmpty);
  });
}
