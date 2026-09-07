import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/server_account.dart';
import 'package:onyx/services/server_registry.dart';
import 'package:onyx/services/progress_sync.dart';

class Registry extends ServerRegistry {
  bool linked = true;
  @override
  List<ServerAccount> linkedAccounts(String id) =>
      linked ? accounts : accounts.where((a) => a.id == id).toList();
  @override
  List<ServerAccount> get accounts => const [
        ServerAccount(id: 'a', url: 'http://a.test', username: 'one'),
        ServerAccount(id: 'b', url: 'http://b.test', username: 'two'),
      ];
  @override
  ServerAccount? accountById(String id) =>
      accounts.where((a) => a.id == id).firstOrNull;
  @override
  Future<String?> tokenFor(String id) async => 'token-$id';
}

class Adapter implements HttpClientAdapter {
  Adapter(this.handle);
  final ResponseBody Function(RequestOptions) handle;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      handle(options);
  @override
  void close({bool force = false}) {}
}

void main() {
  test('unlinked accounts never exchange history', () async {
    final registry = Registry()..linked = false;
    var requests = 0;
    final sync = ProgressSync(registry, clientFactory: (options) {
      requests++;
      return Dio(options);
    });
    await sync.synchronize(force: true);
    expect(requests, 0);
  });
  test('merges newest history, scopes credentials and survives an offline peer',
      () async {
    var offline = false;
    final posts = <String, List<dynamic>>{};
    final reads = <RequestOptions>[];
    final sync = ProgressSync(Registry(), clientFactory: (options) {
      final dio = Dio(options);
      dio.httpClientAdapter = Adapter((request) {
        final a = request.uri.host == 'a.test';
        expect(request.headers['Authorization'],
            a ? 'Bearer token-a' : 'Bearer token-b');
        expect(request.followRedirects, false);
        if (!a && offline) {
          throw DioException(
              requestOptions: request, type: DioExceptionType.connectionError);
        }
        if (request.method == 'GET') {
          reads.add(request);
          return ResponseBody.fromString(
              jsonEncode([
                {
                  'type': 'episode',
                  'tmdb_id': 42,
                  'season_number': 1,
                  'episode_number': 5,
                  'current_position_seconds': a ? 900 : 100,
                  'is_finished': false,
                  'updated_at':
                      a ? '2020-01-01T00:00:00Z' : '2020-01-02T00:00:00Z',
                }
              ]),
              200,
              headers: {
                Headers.contentTypeHeader: [Headers.jsonContentType]
              });
        }
        posts[request.uri.host] = request.data as List;
        return ResponseBody.fromString('{}', 200, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        });
      });
      return dio;
    });
    await sync.synchronize();
    expect(posts.keys, containsAll(['a.test', 'b.test']));
    expect(posts['a.test']!.single['current_position_seconds'], 100);
    expect(posts['b.test']!.single['current_position_seconds'], 100);
    await sync.synchronize();
    expect(reads.length, 2, reason: 'consecutive reads reuse the sync');
    reads.clear();
    await sync.synchronize(force: true, sourceAccountId: 'a', mediaId: 7);
    expect(reads.length, 1);
    expect(reads.single.queryParameters['media_id'], 7);
    offline = true;
    await sync.synchronize(force: true);
    expect(posts['a.test']!.single['current_position_seconds'], 900);
  });
}
