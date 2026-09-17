import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/playback/texture_video_surface.dart';

/// La règle de taille de la texture : suivre l'écran, ne jamais agrandir, et
/// ne pas reconstruire pour trois pixels.
void main() {
  ({int width, int height})? next({
    required Size logical,
    double pixelRatio = 1.0,
    int videoWidth = 3840,
    int videoHeight = 1608,
    ({int width, int height})? current,
  }) =>
      TextureVideoSurface.nextSize(
        logical: logical,
        pixelRatio: pixelRatio,
        videoWidth: videoWidth,
        videoHeight: videoHeight,
        current: current,
      );

  test('une fenêtre plus petite que le média fait rendre à sa taille', () {
    final size = next(logical: const Size(1280, 536));

    expect(size, isNotNull);
    expect(size!.width, 1280);
    expect(size.height, 536);
  });

  test('la densité de l’écran compte : un écran Retina demande ses pixels', () {
    final size = next(logical: const Size(960, 402), pixelRatio: 2.0);

    expect(size!.width, 1920);
  });

  test('une fenêtre plus grande que le média ne fait pas agrandir', () {
    // 4K de large dans un écran 5K : mpv n'a pas ces pixels, les inventer
    // coûterait une passe pour rien.
    final size = next(logical: const Size(5120, 2144));

    expect(size!.width, 3840);
    expect(size.height, 1608);
  });

  test('c’est la dimension la plus contraignante qui décide', () {
    // Fenêtre large mais courte : c'est la hauteur qui borne l'image.
    final size = next(logical: const Size(3840, 400));

    expect(size!.height, 400);
    expect(size.width, lessThan(3840));
  });

  test('les dimensions restent paires, pour la chrominance 4:2:0', () {
    final size = next(logical: const Size(1001, 419));

    expect(size!.width.isEven, isTrue);
    expect(size.height.isEven, isTrue);
  });

  test('un écart de quelques pixels ne reconstruit pas la texture', () {
    final size = next(
      logical: const Size(1290, 540),
      current: (width: 1280, height: 536),
    );

    expect(size, isNull);
  });

  test('un vrai redimensionnement, lui, est suivi', () {
    final size = next(
      logical: const Size(1920, 804),
      current: (width: 1280, height: 536),
    );

    expect(size!.width, 1920);
  });

  test('la pleine résolution est atteinte exactement, même de peu', () {
    // Sans cette exception, le seuil laisserait un plein écran juste sous la
    // résolution du média, donc légèrement flou pour rien.
    final size = next(
      logical: const Size(4000, 2000),
      current: (width: 3800, height: 1591),
    );

    expect(size!.width, 3840);
  });

  test('sans image connue, rien à demander', () {
    expect(next(logical: const Size(1280, 720), videoWidth: 0), isNull);
    expect(next(logical: Size.zero), isNull);
  });
}
