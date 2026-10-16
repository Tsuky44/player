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

  // mpv n'a que l'image entière ou la vue remplie : « Remplir la hauteur »
  // devient l'un ou l'autre selon la forme du film et de la vue.
  test('remplir la hauteur rogne un film large, pas un film étroit', () {
    const tv = Size(1920, 1080);
    expect(
      MpvFraming.properties(BoxFit.fitHeight, 2.39, box: tv)['panscan'],
      '1.0',
    );
    expect(
      MpvFraming.properties(BoxFit.fitHeight, 4 / 3, box: tv)['panscan'],
      '0.0',
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
