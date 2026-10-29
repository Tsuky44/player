import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/app_image_cache.dart';
import 'package:onyx/widgets/global/app_network_image.dart';

/// ADR-0088 : une image dont les octets sont déjà sur disque se pose sans
/// fondu ; seule une image qui vient vraiment du réseau garde le sien.
void main() {
  tearDown(AppImageCache.resetOnDiskForTest);

  Future<CachedNetworkImage> pumpPoster(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(
      home: Center(
        child: AppNetworkImage(
          url: 'https://image.tmdb.org/t/p/w500/dune.jpg',
          width: 150,
          height: 225,
        ),
      ),
    ));
    return tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
  }

  testWidgets('une affiche déjà sur disque apparaît sans fondu',
      (tester) async {
    // L'URL que la carte télécharge vraiment, à la taille de sa place.
    AppImageCache.markOnDiskForTest('https://image.tmdb.org/t/p/w154/dune.jpg');

    final image = await pumpPoster(tester);

    expect(image.fadeInDuration, Duration.zero);
    expect(image.fadeOutDuration, Duration.zero);
  });

  testWidgets('une affiche qui vient du réseau garde son fondu',
      (tester) async {
    final image = await pumpPoster(tester);

    expect(image.fadeInDuration, const Duration(milliseconds: 180));
  });
}
