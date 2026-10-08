import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/playback_access.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_doubles.dart';

const _master = '''
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Français",URI="stream_1.m3u8?ticket=T"
#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,AUDIO="audio"
stream_0.m3u8?ticket=T
''';

PlaybackAccess _access() {
  final access = PlaybackAccess(
    origin: 'http://a.test',
    mediaId: 7,
    token: 'T',
    expiresAt: null,
    renew: () async => DateTime.now(),
    revoke: () async {},
  );
  addTearDown(access.close);
  return access;
}

ApiClient _api(ResponseBody Function(RequestOptions) handle) => ApiClient(
      registry: Registry(),
      httpClient: Dio()..httpClientAdapter = Adapter(handle),
    );

ResponseBody _text(String body, [int status = 200]) =>
    ResponseBody.fromString(body, status, headers: {
      Headers.contentTypeHeader: ['text/plain'],
    });

/// Ce que l'app demande au serveur pour préparer une session à côté de celle
/// qui est lue, et pour mesurer la ligne. Voir ADR-0056.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('la variante vidéo est la ligne qui suit EXT-X-STREAM-INF', () {
    expect(firstHlsVariantUri(_master), 'stream_0.m3u8?ticket=T');
    expect(firstHlsVariantUri('#EXTM3U\n#EXT-X-VERSION:6\n'), isNull);
  });

  test('un serveur qui ne connaît pas l’attente ne la confirme pas', () {
    final old = HlsSession.fromJson({'session_id': 's', 'master_url': 'm'});
    final current = HlsSession.fromJson(
        {'session_id': 's', 'master_url': 'm', 'standby': true});

    expect(old.standby, isFalse);
    expect(current.standby, isTrue);
  });

  test('une session préparée se demande avec standby=1, une session '
      'ordinaire sans', () async {
    final asked = <Map<String, dynamic>>[];
    final api = _api((options) {
      asked.add(options.queryParameters);
      return ResponseBody.fromString(
          jsonEncode({
            'session_id': 's',
            'master_url': 'http://a.test/api/v1/stream/7/s/master.m3u8?ticket=T',
            'standby': options.queryParameters['standby'] == 1,
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          });
    });

    final prepared = await api.startHlsSession(7, '1080p',
        access: _access(), standby: true);
    await api.startHlsSession(7, '1080p', access: _access());

    expect(prepared.standby, isTrue);
    expect(asked.first['standby'], 1);
    expect(asked.last.containsKey('standby'), isFalse);
  });

  test('une session est prête quand sa playlist vidéo annonce un segment',
      () async {
    final fetched = <String>[];
    var playlist = '#EXTM3U\n#EXTINF:2.0,\nstream_0_000.ts?ticket=T\n';
    final api = _api((options) {
      fetched.add(options.uri.path);
      return options.uri.path.endsWith('master.m3u8')
          ? _text(_master)
          : _text(playlist);
    });
    const master = 'http://a.test/api/v1/stream/7/s/master.m3u8?ticket=T';

    expect(await api.awaitHlsReady(master), isTrue);
    expect(fetched, [
      '/api/v1/stream/7/s/master.m3u8',
      '/api/v1/stream/7/s/stream_0.m3u8',
    ]);

    playlist = '#EXTM3U\n';
    expect(await api.awaitHlsReady(master), isFalse);
  });

  test('une session morte n’est jamais prête', () async {
    final api = _api((options) => _text('not ready', 503));

    expect(
      await api.awaitHlsReady(
          'http://a.test/api/v1/stream/7/s/master.m3u8?ticket=T'),
      isFalse,
    );
  });

  test('la mesure de la ligne tire deux secondes du débit visé, pas plus',
      () async {
    String? range;
    final api = _api((options) {
      range = options.headers['Range'] as String?;
      return ResponseBody.fromBytes(Uint8List(1024 * 1024), 206);
    });

    final bps = await api.measureLineBps(7,
        access: _access(), wantBps: 8 * 1000 * 1000);

    expect(range, 'bytes=0-1999999');
    expect(bps, isNotNull);
    expect(bps!, greaterThan(8 * 1000 * 1000),
        reason: 'un mégaoctet arrivé d’un coup, c’est une ligne rapide');
  });

  test('une mesure où presque rien n’arrive ne prouve rien', () async {
    final api =
        _api((options) => ResponseBody.fromBytes(Uint8List(1000), 206));

    expect(
      await api.measureLineBps(7, access: _access(), wantBps: 8000000),
      isNull,
    );
  });
}
