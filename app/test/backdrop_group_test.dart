@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/player_layout.dart';
import 'package:onyx/widgets/global/control_chrome.dart';

/// Les fichiers dont le verre est posé sur le film ou sur la page, et qui
/// doivent donc partager le fond du [BackdropGroup] de leur écran.
///
/// Ce qui n'est pas dans cette liste couvre le chrome plutôt que le film — un
/// menu de réglages, la fiche, le panneau des épisodes — et garde un
/// `BackdropFilter` ordinaire : il doit flouter ce qu'il recouvre, y compris
/// le verre d'en dessous. Voir l'ADR-0025.
const List<String> _groupedGlass = [
  'lib/widgets/global/control_chrome.dart',
  'lib/screens/shell/main_shell.dart',
  'lib/screens/player/widgets/top_right_controls.dart',
  'lib/screens/player/widgets/skip_intro_button.dart',
  'lib/screens/player/widgets/player_hud_overlay.dart',
];

/// `glass_chrome.dart` tient les deux cas à lui seul, et c'est la frontière
/// elle-même qu'on garde ici : la bande d'en-tête est posée sur la page et
/// partage son fond ; `GlassSurface` sert aux surfaces qui viennent par-dessus
/// — la recherche du catalogue, le menu de compte — et doit continuer de
/// flouter l'en-tête qu'elle recouvre, donc de lire son propre fond.
const String _mixedGlass = 'lib/widgets/global/glass_chrome.dart';

/// Les écrans qui doivent ouvrir le groupe au-dessus de ce verre-là.
const List<String> _groupHosts = [
  'lib/screens/player/player_screen.dart',
  'lib/screens/shell/main_shell.dart',
  'lib/screens/player_studio/widgets/studio_canvas.dart',
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
          'l’image derrière lui, à chaque image du film. Une disposition '
          'modulaire en pose autant qu’elle a de contrôles. Voir '
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

  testWidgets('les contrôles d’une disposition lisent le même fond',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BackdropGroup(
          child: Stack(
            children: [
              for (final type in [
                PlayerControlType.playPause,
                PlayerControlType.rewind,
                PlayerControlType.forward,
              ])
                ControlChrome(
                  type: type,
                  sizePercentage: 0.06,
                  canvasSize: const Size(1280, 720),
                  variant: ControlChromeVariant.live,
                ),
            ],
          ),
        ),
      ),
    );

    final keys = tester
        .renderObjectList<RenderBackdropFilter>(find.byType(BackdropFilter))
        .map((render) => render.backdropKey)
        .toList();

    expect(keys, isNotEmpty);
    expect(keys.every((key) => key != null), isTrue,
        reason: 'Un contrôle qui n’a pas trouvé le groupe relit le fond pour '
            'lui seul.');
    expect(keys.toSet(), hasLength(1),
        reason: 'Les contrôles d’une même disposition doivent partager une '
            'seule lecture du film.');
  });

  testWidgets('sans groupe, le même contrôle reste un flou ordinaire',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ControlChrome(
          type: PlayerControlType.playPause,
          sizePercentage: 0.06,
          canvasSize: const Size(1280, 720),
          variant: ControlChromeVariant.live,
        ),
      ),
    );

    final keys = tester
        .renderObjectList<RenderBackdropFilter>(find.byType(BackdropFilter))
        .map((render) => render.backdropKey);
    expect(keys.every((key) => key == null), isTrue,
        reason: 'Le studio et le lecteur fournissent le groupe ; hors d’eux le '
            'widget doit continuer de fonctionner seul.');
  });
}
