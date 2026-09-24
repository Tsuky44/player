import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/app_download.dart';
import 'package:onyx/services/auto_updater_service.dart';

const _update = AppDownload(
  platform: 'android',
  label: 'Android',
  file: 'onyx.apk',
  url: '/downloads/onyx.apk',
  version: '2.0.0',
  size: 1,
);

void main() {
  test('une mise à jour trouvée hors lecture est proposée une seule fois',
      () async {
    final found = <AppDownload>[];
    final service = AutoUpdateService(
      findUpdate: () async => _update,
      onUpdateFound: found.add,
      isPlaying: () => false,
      initialDelay: const Duration(milliseconds: 1),
      interval: const Duration(milliseconds: 5),
    )..start();

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(found, [_update]);
    service.dispose();
  });

  test('pendant la lecture, la mise à jour attend le prochain démarrage',
      () async {
    var playing = true;
    final found = <AppDownload>[];
    final service = AutoUpdateService(
      findUpdate: () async => _update,
      onUpdateFound: found.add,
      isPlaying: () => playing,
      initialDelay: const Duration(milliseconds: 1),
      interval: const Duration(milliseconds: 5),
    )..start();

    await Future<void>.delayed(const Duration(milliseconds: 10));
    playing = false;
    // Le film est fini, mais la session ne la propose plus.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(found, isEmpty);
    service.dispose();
  });
}
