import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/widgets/direct_source_label.dart';

void main() {
  test('un média téléchargé se nomme « Téléchargé » dans le menu Qualité', () {
    final direct = directSourceLabel(local: true, streamSubtitle: 'Le fichier');

    expect(direct.label, 'Téléchargé');
    // Le sous-titre du flux ne vaut plus : rien ne vient du serveur.
    expect(direct.subtitle, isNot('Le fichier'));
  });

  test('un flux du serveur reste « Direct », avec le sous-titre du menu', () {
    final direct = directSourceLabel(local: false, streamSubtitle: 'Le fichier');

    expect(direct.label, 'Direct');
    expect(direct.subtitle, 'Le fichier');
  });
}
