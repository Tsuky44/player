import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/l10n/app_language.dart';
import 'package:onyx/services/api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_doubles.dart';

/// Les titres et synopsis suivent la langue de l'interface (ADR-0049) : l'app
/// l'annonce sur chaque requête, et le serveur répond dans cette langue.

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(AppLanguage.resetForTest);

  Future<String?> announcedLanguage() async {
    String? announced;
    final dio = Dio()
      ..httpClientAdapter = Adapter((options) {
        announced = options.headers['Accept-Language'] as String?;
        return ResponseBody.fromString(
          jsonEncode(const <Object>[]),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
    await ApiClient(httpClient: dio).getMovies();
    return announced;
  }

  test('each request announces the interface language', () async {
    expect(await announcedLanguage(), 'fr');

    AppLanguage.notifier.value = AppLanguage.english;
    expect(await announcedLanguage(), 'en');
  });

  test('the language is read at request time, not at construction', () async {
    String? announced;
    final dio = Dio()
      ..httpClientAdapter = Adapter((options) {
        announced = options.headers['Accept-Language'] as String?;
        return ResponseBody.fromString(
          jsonEncode(const <Object>[]),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
    final api = ApiClient(httpClient: dio);

    await api.getMovies();
    expect(announced, 'fr');

    AppLanguage.notifier.value = AppLanguage.english;
    await api.getMovies();
    expect(announced, 'en');
  });
}
