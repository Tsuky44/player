import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/utils/mpv_native_view.dart';

/// Le choix du libmpv se fait avant le premier écran : un mauvais choix ne
/// donne pas un message d'erreur mais une app qui ne démarre pas, ou qui
/// ouvre une fenêtre mpv à côté d'elle.
void main() {
  test('le libmpv désigné au lancement passe avant celui installé', () {
    expect(
      MpvNativeView.pick(['/dev/libmpv', '/installe/libmpv'], (_) => true),
      '/dev/libmpv',
    );
  });

  test('un binaire qui ne se charge pas est sauté', () {
    expect(
      MpvNativeView.pick(['/casse', '/installe'], (p) => p == '/installe'),
      '/installe',
    );
  });

  test('sans libmpv patché, la texture de media_kit reste', () {
    expect(MpvNativeView.pick(['/a', '/b'], (_) => false), isNull);
  });
}
