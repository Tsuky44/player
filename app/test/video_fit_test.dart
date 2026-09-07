import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/video_fit.dart';

void main() {
  BoxFit onPhone(BoxFit chosen) =>
      VideoFitRendering.resolve(chosen, handheld: true);
  BoxFit onTelevision(BoxFit chosen) =>
      VideoFitRendering.resolve(chosen, handheld: false);

  group('what "original" is drawn as', () {
    test('a screen held in a hand fills its height', () {
      // The complaint this answers: on a phone held sideways, original meant
      // black bars across the top and bottom of an already small screen — the
      // framing paid for in the one place where the picture is scarce.
      expect(onPhone(BoxFit.contain), BoxFit.fitHeight);
    });

    test('a television keeps the letterbox', () {
      // A scope film with bars is what a scope film looks like, and a set has
      // the room to say so.
      expect(onTelevision(BoxFit.contain), BoxFit.contain);
    });

    test('adaptive is the same everywhere', () {
      // It already means "fill the screen, crop what has to go", and that
      // reads the same on any screen.
      expect(onPhone(BoxFit.cover), BoxFit.cover);
      expect(onTelevision(BoxFit.cover), BoxFit.cover);
    });

    test('anything else is passed through untouched', () {
      expect(onPhone(BoxFit.fitHeight), BoxFit.fitHeight);
      expect(onPhone(BoxFit.fill), BoxFit.fill);
    });
  });
}
