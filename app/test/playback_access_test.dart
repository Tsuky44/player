import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onyx/models/server_account.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/playback_access.dart';
import 'progress_sync_test.dart' show Adapter, Registry;

class _Registry extends Registry {
  @override
  Future<void> load() async {}
  @override
  ServerAccount get active => accounts.first;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final secret = 'a' * 43;
  ResponseBody json(Object body, [int status = 200]) =>
      ResponseBody.fromString(jsonEncode(body), status, headers: {
        Headers.contentTypeHeader: ['application/json']
      });

  test('ticket is used on direct, subtitles and HLS; close revokes once',
      () async {
    var revokes = 0;
    final dio = Dio();
    dio.httpClientAdapter = Adapter((r) {
      if (r.uri.path == '/api/playback/tickets') {
        expect(r.headers['Authorization'], 'Bearer token-a');
        if (r.method == 'DELETE') {
          revokes++;
          return json({});
        }
        expect(r.data['media_id'], 7);
        return json({
          'ticket': secret,
          'expires_at':
              DateTime.now().add(const Duration(minutes: 15)).toIso8601String()
        });
      }
      expect(r.headers.containsKey('Authorization'), false,
          reason: 'media URLs must not receive the active account credential');
      expect(r.uri.queryParameters['ticket'], secret);
      if (r.uri.path.endsWith('.vtt')) {
        return ResponseBody.fromString('WEBVTT\n', 200);
      }
      return json({
        'session_id': 's',
        'master_url': 'http://a.test/master.m3u8?ticket=$secret'
      });
    });
    final api = ApiClient(registry: _Registry(), httpClient: dio);
    final lease = await api.openPlaybackAccess(7);
    expect(
        Uri.parse(api.getStreamUrl(7, access: lease)).queryParameters['ticket'],
        secret);
    expect(() => api.getStreamUrl(8, access: lease), throwsStateError);
    expect(await api.fetchSubtitleContent(7, 'fra', access: lease), 'WEBVTT\n');
    await api.startHlsSession(7, '720p', access: lease);
    await api.setConnection('http://b.test', token: 'token-b');
    expect(api.baseUrl, 'http://b.test');
    expect(Uri.parse(api.getStreamUrl(7, access: lease)).host, 'a.test');
    await api.destroyHlsSession(7, 's', access: lease);
    await lease.close();
    await lease.close();
    expect(revokes, 1);
    expect(() => lease.query, throwsStateError);
    expect(lease.toString(), isNot(contains(secret)));
  });

  test('only a confirmed old server allows unsigned URLs', () async {
    for (final code in [401, 403, 404, 405, 500]) {
      for (final modern in [true, false]) {
        var pings = 0;
        final dio = Dio();
        dio.httpClientAdapter = Adapter((r) {
          if (r.path == '/api/ping') {
            pings++;
            return json(
                {'status': 'ok', if (modern) 'playback_ticket_version': 1});
          }
          return json({'error': 'unavailable'}, code);
        });
        final api = ApiClient(registry: _Registry(), httpClient: dio);
        if (!modern && (code == 404 || code == 405)) {
          final lease = await api.openPlaybackAccess(7);
          expect(lease.isLegacy, true);
          expect(api.getStreamUrl(7, access: lease),
              'http://a.test/stream?media_id=7');
          await lease.close();
        } else {
          await expectLater(
              api.openPlaybackAccess(7), throwsA(isA<DioException>()));
        }
        expect(pings, code == 404 || code == 405 ? 1 : 0);
      }
    }
  });

  test('separate leases cannot revoke each other or cross origins', () async {
    var revoked = 0;
    PlaybackAccess lease() => PlaybackAccess(
        origin: 'http://a.test',
        mediaId: 7,
        token: secret,
        expiresAt: DateTime.now().add(const Duration(minutes: 15)),
        renew: () async => DateTime.now().add(const Duration(minutes: 15)),
        revoke: () async {
          revoked++;
        });
    final a = lease(), b = lease();
    expect(() => a.protect('http://b.test/stream'), throwsStateError);
    await a.close();
    expect(b.query['ticket'], secret);
    expect(revoked, 1);
    await b.close();
  });

  testWidgets('renewal preserves token and stops after close', (tester) async {
    var renewals = 0;
    final lease = PlaybackAccess(
        origin: 'http://a.test',
        mediaId: 7,
        token: secret,
        expiresAt: DateTime.now().add(const Duration(minutes: 15)),
        renewEvery: const Duration(seconds: 1),
        renew: () async {
          renewals++;
          return DateTime.now().add(const Duration(minutes: 15));
        },
        revoke: () async {});
    await tester.pump(const Duration(seconds: 1));
    expect(renewals, 1);
    expect(lease.query['ticket'], secret);
    await lease.close();
    await tester.pump(const Duration(seconds: 3));
    expect(renewals, 1);
  });

  test('expired authorization never produces an unsigned URL', () async {
    final lease = PlaybackAccess(
        origin: 'http://a.test',
        mediaId: 7,
        token: secret,
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
        renew: () async => DateTime.now(),
        revoke: () async {});
    expect(() => lease.protect('http://a.test/stream'), throwsStateError);
    await lease.close();
  });

  test('diagnostics conceal URL secrets', () {
    final message = redactPlaybackDiagnostic(
        'GET https://nas.test/stream?ticket=$secret failed; ticket=$secret');
    expect(message, isNot(contains(secret)));
    expect(message, isNot(contains('nas.test')));
    expect(redactPlaybackDiagnostic('Authorization: Bearer $secret'),
        isNot(contains(secret)));
    expect(redactPlaybackDiagnostic(jsonEncode({'ticket': secret})),
        isNot(contains(secret)));
  });
}
