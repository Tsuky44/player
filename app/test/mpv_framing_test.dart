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
    });
  });

  test('cover remplit l\'écran en recadrant', () {
    expect(MpvFraming.properties(BoxFit.cover, null)['panscan'], '1.0');
    expect(MpvFraming.properties(BoxFit.cover, null)['keepaspect'], 'yes');
  });

  test('fill étire sans garder le rapport', () {
    expect(MpvFraming.properties(BoxFit.fill, null)['keepaspect'], 'no');
  });

  test('les autres cadrages retombent sur contain', () {
    expect(
      MpvFraming.properties(BoxFit.fitHeight, null),
      MpvFraming.properties(BoxFit.contain, null),
    );
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
