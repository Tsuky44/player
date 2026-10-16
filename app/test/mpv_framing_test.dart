import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/playback/mpv_native_surface.dart';

/// Dans la vue native, c'est mpv qui cadre l'image : le cadrage choisi à
/// l'écran doit lui arriver sous forme d'options, sinon il resterait figé.
void main() {
  test('contain garde le rapport et laisse les bandes', () {
    expect(MpvFraming.properties(BoxFit.contain, null), {
      'keepaspect': 'yes',
      'panscan': '0.0',
      'video-aspect-override': 'no',
      'video-zoom': '0.0000',
      'video-pan-x': '0.0000',
      'video-pan-y': '0.0000',
    });
  });

  test('cover remplit l\'écran en recadrant', () {
    expect(MpvFraming.properties(BoxFit.cover, null)['panscan'], '1.0');
    expect(MpvFraming.properties(BoxFit.cover, null)['keepaspect'], 'yes');
  });

  test('fill étire sans garder le rapport', () {
    expect(MpvFraming.properties(BoxFit.fill, null)['keepaspect'], 'no');
  });

  // Avec la place connue, le cadre se dit à mpv en zoom (log₂) depuis
  // l'image entière, pas en panscan (ADR-0067).
  test('remplir la hauteur zoome un film large, pas un film étroit', () {
    const tv = Size(1920, 1080);
    final wide = MpvFraming.properties(BoxFit.fitHeight, 2.39, box: tv);
    expect(wide['panscan'], '0.0');
    expect(wide['video-zoom'], '0.4269');
    expect(wide['video-pan-x'], '0.0000');
    expect(wide['video-pan-y'], '0.0000');
    expect(
      MpvFraming.properties(BoxFit.fitHeight, 4 / 3, box: tv)['video-zoom'],
      '0.0000',
    );
  });

  test('sans place connue, seul cover rogne', () {
    expect(
      MpvFraming.properties(BoxFit.fitHeight, 2.39)['panscan'],
      '0.0',
    );
    expect(MpvFraming.properties(BoxFit.cover, 2.39)['panscan'], '1.0');
  });

  test('un rapport imposé passe à mpv, un rapport nul non', () {
    expect(
      MpvFraming.properties(BoxFit.contain, 2.39)['video-aspect-override'],
      '2.39',
    );
    expect(
      MpvFraming.properties(BoxFit.contain, 0)['video-aspect-override'],
      'no',
    );
  });
}
