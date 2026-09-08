import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/widgets/global/media_technical_section.dart';

void main() {
  test('la résolution reconnaît les fichiers cinéma sans bandes noires', () {
    for (final entry in {3840: '4K', 1920: '1080p', 1280: '720p'}.entries) {
      final video = MediaVideoTrack(
          codec: 'hevc', width: entry.key, height: (entry.key / 2.4).round());
      expect(video.resolutionLabel, entry.value);
      expect(video.codecLabel, 'HEVC (H.265)');
    }
  });

  testWidgets('les formats vidéo et toutes les pistes tiennent sur mobile',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final tracks = MediaTracks.fromJson({
      'video': {
        'codec_name': 'hevc',
        'width': 3840,
        'height': 1600,
        'hdr_format': 'dolbyvision',
        'bit_depth': 10
      },
      'audio': [
        {
          'codec_name': 'eac3',
          'language': 'fre',
          'channels': 6,
          'spatial_format': 'atmos'
        },
        {
          'codec_name': 'dts',
          'language': 'eng',
          'channels': 8,
          'lossless': true
        },
      ],
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: SingleChildScrollView(
          child: MediaTechnicalSection(
        tracks: tracks,
        loading: false,
        failed: false,
        onRetry: () {},
      )),
    )));
    expect(find.text('4K'), findsOneWidget);
    expect(find.text('HEVC (H.265)'), findsOneWidget);
    expect(find.text('Dolby Vision'), findsOneWidget);
    expect(find.textContaining('Dolby Atmos 5.1'), findsOneWidget);
    expect(find.textContaining('DTS-HD MA 7.1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('une erreur permet de réessayer sans inventer de formats',
      (tester) async {
    var retries = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: MediaTechnicalSection(
          tracks: null, loading: false, failed: true, onRetry: () => retries++),
    )));
    await tester.tap(find.text('Réessayer'));
    expect(retries, 1);
    expect(find.text('4K'), findsNothing);
  });
}
