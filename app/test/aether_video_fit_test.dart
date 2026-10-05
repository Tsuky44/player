import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/playback/aether_video_fit.dart';
import 'package:onyx/screens/player/playback/native_video_framing.dart';
import 'package:onyx_player_apple/onyx_player_apple.dart';

/// Sur les appareils Apple, c'est la couche vidéo qui cadre : chaque réglage
/// de l'app doit se réduire à « image entière » ou « vue remplie ».
void main() {
  const phone = Size(844, 390);
  const tablet = Size(1180, 820);
  const scope = 2.39;
  const episode = 16 / 9;

  test('« Adaptatif » remplit la vue dès que l\'image n\'a pas sa forme', () {
    expect(
      AetherVideoFit.resolve(BoxFit.cover, episode, phone),
      OnyxAppleVideoFit.cover,
    );
    expect(
      AetherVideoFit.resolve(BoxFit.cover, scope, tablet),
      OnyxAppleVideoFit.cover,
    );
  });

  test('« Original » montre l\'image entière', () {
    expect(
      AetherVideoFit.resolve(BoxFit.contain, scope, tablet),
      OnyxAppleVideoFit.contain,
    );
    expect(
      AetherVideoFit.resolve(BoxFit.contain, episode, phone),
      OnyxAppleVideoFit.contain,
    );
  });

  test('remplir la hauteur rogne un film large, pas un épisode', () {
    expect(
      AetherVideoFit.resolve(BoxFit.fitHeight, scope, phone),
      OnyxAppleVideoFit.cover,
    );
    expect(
      AetherVideoFit.resolve(BoxFit.fitHeight, episode, phone),
      OnyxAppleVideoFit.contain,
    );
  });

  test('une image à la forme de la vue reste entière', () {
    expect(
      AetherVideoFit.resolve(BoxFit.cover, 16 / 9, const Size(1920, 1080)),
      OnyxAppleVideoFit.contain,
    );
  });

  test('sans place ni dimensions, l\'image reste entière', () {
    expect(
      AetherVideoFit.resolve(BoxFit.cover, episode, Size.zero),
      OnyxAppleVideoFit.contain,
    );
    expect(
      AetherVideoFit.resolve(BoxFit.cover, 0, phone),
      OnyxAppleVideoFit.contain,
    );
  });

  // `applyBoxFit` rend la boîte pour un cadrage qui rogne : la vue native
  // gardait la taille de l'écran et « Adaptatif » ne changeait rien.
  test('un cadrage qui rogne donne une image plus grande que la vue', () {
    final framed = NativeVideoFraming.framedSize(BoxFit.cover, episode, phone);
    expect(framed.width, phone.width);
    expect(framed.height, closeTo(phone.width / episode, 0.01));
    expect(framed.height, greaterThan(phone.height));

    final filled =
        NativeVideoFraming.framedSize(BoxFit.fitHeight, scope, phone);
    expect(filled.height, phone.height);
    expect(filled.width, greaterThan(phone.width));
  });

  test('un cadrage entier tient dans la vue', () {
    final framed = NativeVideoFraming.framedSize(BoxFit.contain, scope, tablet);
    expect(framed.width, tablet.width);
    expect(framed.height, closeTo(tablet.width / scope, 0.01));
  });
}
