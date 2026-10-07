@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Les fichiers dont le verre est posé sur le film ou sur la page, et qui
/// doivent donc partager le fond du [BackdropGroup] de leur écran.
///
/// Ce qui n'est pas dans cette liste couvre le chrome plutôt que le film — un
/// menu de réglages, la fiche, le panneau des épisodes — et garde un
/// `BackdropFilter` ordinaire : il doit flouter ce qu'il recouvre, y compris
/// le verre d'en dessous. Voir l'ADR-0025.
const List<String> _groupedGlass = [
  'lib/screens/shell/main_shell.dart',
];

/// `glass_chrome.dart` tient les deux cas à lui seul, et c'est la frontière
/// elle-même qu'on garde ici : la bande d'en-tête est posée sur la page et
/// partage son fond ; `GlassSurface` sert aux surfaces qui viennent par-dessus
/// — la recherche du catalogue, le menu de compte — et doit continuer de
/// flouter l'en-tête qu'elle recouvre, donc de lire son propre fond.
const String _mixedGlass = 'lib/widgets/global/glass_chrome.dart';

/// Les écrans qui doivent ouvrir le groupe au-dessus de ce verre-là.
const List<String> _groupHosts = [
  'lib/screens/shell/main_shell.dart',
];

void main() {
  test('le verre du chrome partage un seul fond', () {
    final offenders = <String>[];
    for (final path in _groupedGlass) {
      final source = File(path).readAsStringSync();
      final total = RegExp(r'BackdropFilter[.(]').allMatches(source).length;
      final grouped =
          RegExp(r'BackdropFilter\.grouped\(').allMatches(source).length;
      if (grouped < total) {
        offenders.add('$path : $total flou(s), $grouped groupé(s)');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Chaque BackdropFilter non groupé redemande sa propre copie de '
          'l’image derrière lui, à chaque image. Voir '
          'docs/adr/0025-poids-de-l-interface-sous-windows.md.',
    );
  });

  test('la bande d’en-tête partage, les surfaces posées dessus non', () {
    final source = File(_mixedGlass).readAsStringSync();
    final strip = source.indexOf('class GlassHeaderStrip');
    final surface = source.indexOf('class GlassSurface');
    expect(strip, greaterThanOrEqualTo(0));
    expect(surface, greaterThan(strip));

    expect(source.substring(strip, surface).contains('BackdropFilter.grouped('),
        isTrue,
        reason: 'GlassHeaderStrip est posée sur la page : elle partage le fond '
            'de la coquille avec la barre d’onglets.');
    expect(
        source.substring(surface).contains('child: BackdropFilter(') &&
            !source.substring(surface).contains('BackdropFilter.grouped('),
        isTrue,
        reason: 'GlassSurface couvre l’en-tête. La mettre dans le groupe lui '
            'ferait flouter la page au lieu du verre qu’elle recouvre.');
  });

  test('les écrans qui portent ce verre ouvrent le groupe', () {
    for (final path in _groupHosts) {
      expect(
        File(path).readAsStringSync().contains('BackdropGroup('),
        isTrue,
        reason: '$path pose du verre groupé sans fournir de BackdropGroup : '
            'chaque flou retomberait silencieusement sur sa propre lecture.',
      );
    }
  });
}
