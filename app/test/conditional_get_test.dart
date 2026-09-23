import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/conditional_get.dart';

/// Un serveur qui répond comme `writeETaggedJSON`.
class _EtagServer implements HttpClientAdapter {
  String body = '[1]';
  final List<String?> sentIfNoneMatch = [];

  String get _etag => '"${body.hashCode}"';

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? _, Future<void>? __) async {
    final ifNoneMatch = options.headers['If-None-Match'] as String?;
    sentIfNoneMatch.add(ifNoneMatch);
    if (ifNoneMatch == _etag) {
      return ResponseBody.fromString('', 304, headers: {
        'etag': [_etag],
      });
    }
    return ResponseBody.fromString(body, 200, headers: {
      'etag': [_etag],
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('un document inchangé est repris du cache sur un 304', () async {
    final server = _EtagServer();
    final dio = Dio()..httpClientAdapter = server;
    final cache = ConditionalGetCache();

    expect(await cache.get(dio, '/api/movies', scope: 'a'), [1]);
    expect(await cache.get(dio, '/api/movies', scope: 'a'), [1]);
    expect(server.sentIfNoneMatch, [null, '"${'[1]'.hashCode}"']);

    server.body = jsonEncode([1, 2]);
    expect(await cache.get(dio, '/api/movies', scope: 'a'), [1, 2]);
  });

  test('chaque compte a son propre document', () async {
    final server = _EtagServer();
    final dio = Dio()..httpClientAdapter = server;
    final cache = ConditionalGetCache();

    await cache.get(dio, '/api/movies', scope: 'a');
    await cache.get(dio, '/api/movies', scope: 'b');
    expect(server.sentIfNoneMatch, [null, null]);
  });
}
