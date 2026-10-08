// Banc d'essai temporaire de la qualité automatique (ADR-0056) : lit un film
// du serveur de test local avec le vrai moteur, change le débit de la ligne
// en cours de route et note ce que fait le lecteur. Pas livré.
//
//   flutter run -d windows -t tool/auto_probe_main.dart \
//     --dart-define=E2E_TOKEN=… --dart-define=E2E_PLAN=14000@0,5000@40,0@200
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:onyx/models/models.dart';
import 'package:onyx/models/server_account.dart';
import 'package:onyx/screens/player/hardware_decoding.dart';
import 'package:onyx/screens/player/hooks/use_player_controller.dart';
import 'package:onyx/screens/player/playback_profile.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/playback_capabilities.dart';
import 'package:onyx/services/server_registry.dart';
import 'package:onyx/utils/mpv_native_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _base = String.fromEnvironment('E2E_BASE',
    defaultValue: 'http://localhost:18080');
const _token = String.fromEnvironment('E2E_TOKEN');
const _plan =
    String.fromEnvironment('E2E_PLAN', defaultValue: '14000@0,5000@40,0@200');
const _lasts = int.fromEnvironment('E2E_SECONDS', defaultValue: 420);

class _Registry extends ServerRegistry {
  @override
  List<ServerAccount> get accounts =>
      const [ServerAccount(id: 'e2e', url: _base, username: 'essai')];
  @override
  List<ServerAccount> linkedAccounts(String id) => accounts;
  @override
  ServerAccount? accountById(String id) => accounts.first;
  @override
  Future<String?> tokenFor(String id) async => _token;
}

void _log(String line) {
  // ignore: avoid_print
  print('E2E $line');
}

Future<void> _setLine(int kbps) async {
  await Dio().put('$_base/api/dev/line',
      queryParameters: {'kbps': kbps},
      options: Options(headers: {'Authorization': 'Bearer $_token'}));
  _log('ligne réglée à $kbps kbit/s');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // En mémoire : le banc ne touche pas aux réglages de l'app installée.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  MpvNativeView.resolve();
  MediaKit.ensureInitialized(libmpv: MpvNativeView.libmpvPath);
  await PlaybackCapabilitiesResolver.initialize();
  await HardwareDecoding.initialize();
  await PlaybackProfiles.initialize(isTv: false);

  final steps = [
    for (final step in _plan.split(','))
      (kbps: int.parse(step.split('@')[0]), at: int.parse(step.split('@')[1])),
  ];
  await _setLine(steps.first.kbps);

  final api = await ApiClient(registry: _Registry()).pinToAccount('e2e');
  final controller = PlayerController();
  final repaint = ValueNotifier(0);
  runApp(MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: ValueListenableBuilder(
        valueListenable: repaint,
        builder: (_, __, ___) => Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: controller.session.buildSurface(fit: BoxFit.contain),
          ),
        ),
      ),
    ),
  ));

  final media = Media(
    id: 1,
    type: MediaType.movie,
    title: 'Essai Auto',
    duration: 600,
    createdAt: DateTime(2026),
  );
  await controller.init(
    media: media,
    apiClient: api,
    onCompleted: () => _log('fin du média'),
    onPositionChanged: () {},
    onDurationChanged: () {},
    onQualitySwitchingChanged: () =>
        _log('sablier ${controller.isSwitchingQuality ? 'affiché' : 'retiré'}'),
    onBufferingChanged: () =>
        _log('tampon ${controller.isBuffering ? 'VIDE' : 'regarni'}'),
    onFirstFrame: () => repaint.value++,
    resumePositionFuture: Future.value(0),
  );
  // Le film d'essai est un sifflement continu : personne n'a à l'entendre.
  await controller.session.setVolume(0);
  await controller.startPlayback(mediaId: 1, apiClient: api);
  await controller.session.setVolume(0);

  final clock = Stopwatch()..start();
  var next = 1;

  // Le gel de l'image : la position n'avance plus alors que la lecture est
  // censée tourner.
  var lastPosition = Duration.zero;
  var lastMoved = clock.elapsed;
  // Chaque changement de position est comparé au temps réellement écoulé :
  // un écart dit un saut (du film perdu) ou un retour (du film revu).
  var lastSeen = clock.elapsed;
  var lastSeenPosition = Duration.zero;
  Timer.periodic(const Duration(milliseconds: 50), (_) {
    final now = clock.elapsed;
    if (controller.position != lastPosition) {
      final gap = now - lastMoved;
      final jump = controller.position - lastPosition;
      if (gap > const Duration(milliseconds: 400)) {
        _log('GEL de ${(gap.inMilliseconds / 1000).toStringAsFixed(2)} s, '
            'reprise à ${controller.position.inMilliseconds / 1000} s '
            '(saut de ${jump.inMilliseconds} ms)');
      }
      final drift = (controller.position - lastSeenPosition) - (now - lastSeen);
      if (lastSeenPosition > Duration.zero &&
          drift.inMilliseconds.abs() > 250 &&
          gap <= const Duration(milliseconds: 400)) {
        _log('ECART de ${drift.inMilliseconds} ms à '
            '${controller.position.inMilliseconds / 1000} s '
            '(film ${drift.isNegative ? 'revu' : 'sauté'})');
      }
      lastSeen = now;
      lastSeenPosition = controller.position;
      lastPosition = controller.position;
      lastMoved = now;
    }
  });

  Timer.periodic(const Duration(seconds: 1), (timer) async {
    final t = clock.elapsed.inSeconds;
    if (next < steps.length && t >= steps[next].at) {
      await _setLine(steps[next++].kbps);
    }
    _log('t=$t q=${controller.currentQuality ?? 'direct'} '
        'auto=${controller.isAutoQuality} '
        'pos=${(controller.position.inMilliseconds / 1000).toStringAsFixed(1)} '
        'avance=${controller.session.bufferedAhead.inSeconds}s '
        '${controller.isBuffering ? 'TAMPON ' : ''}'
        '${controller.isSwitchingQuality ? 'SABLIER' : ''}');
    if (t >= _lasts) {
      timer.cancel();
      await _setLine(0);
      controller.dispose();
      await Future<void>.delayed(const Duration(seconds: 2));
      exit(0);
    }
  });
}
