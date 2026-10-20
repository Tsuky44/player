import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_doubles.dart';

/// Le bouton « Tester » de la liaison avec OnyxHub fait vérifier la liaison
/// par le serveur, seul à savoir s'il joint OnyxHub (ADR-0072).

ResponseBody _json(Object body) => ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

ApiClient _server(List<RequestOptions> requests,
    {required List<String> capabilities}) {
  final dio = Dio()
    ..httpClientAdapter = Adapter((options) {
      requests.add(options);
      return switch (options.uri.path) {
        '/api/ping' => _json({'status': 'ok', 'capabilities': capabilities}),
        '/api/settings/mediahub/test' =>
          _json({'ok': false, 'message': 'OnyxHub répond, mais refuse cette clé.'}),
        _ => _json(const <String, Object>{}),
      };
    });
  return ApiClient(httpClient: dio);
}

void main() {
  // L'ApiClient lit ses préférences d'appareil avant chaque requête.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('un serveur qui ne sait pas tester la liaison ne reçoit pas la demande',
      () async {
    final requests = <RequestOptions>[];
    final api = _server(requests, capabilities: const []);

    expect(await api.testMediaHubLink(url: 'http://hub:4400'), isNull);
    expect(requests.map((r) => r.uri.path), ['/api/ping']);
  });

  test('le test porte sur les valeurs du formulaire, et son échec reste lisible',
      () async {
    final requests = <RequestOptions>[];
    final api = _server(requests, capabilities: const ['mediahub_link_test']);

    final result =
        await api.testMediaHubLink(url: 'http://hub:4400', apiKey: '');

    expect(result?.ok, isFalse);
    expect(result?.message, contains('refuse'));
    final sent = requests.last;
    expect(sent.method, 'POST');
    // Une clé vide n'est pas envoyée : le serveur teste alors celle enregistrée.
    expect(sent.data, {'mediahub_url': 'http://hub:4400'});
  });
}
