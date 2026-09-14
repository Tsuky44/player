import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/settings/widgets/settings_ui.dart';
import 'package:onyx/theme/app_colors.dart';

void main() {
  for (final width in [360.0, 1100.0]) {
    testWidgets('settings controls remain usable at width $width',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var enabled = false;
      var actionCount = 0;
      final capture = GlobalKey();

      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: AppColors.background,
          colorScheme: const ColorScheme.dark(primary: AppColors.primary),
        ),
        home: RepaintBoundary(
          key: capture,
          child: Scaffold(
            appBar: width < 840 ? AppBar(title: const Text('Lecture')) : null,
            body: SettingsLayout(
              isWide: width >= 840,
              openSection: (_) {},
              child: StatefulBuilder(builder: (context, setState) {
                return SettingsPage(
                  title: 'Lecture',
                  description: 'Personnalisez la lecture sur cet appareil.',
                  actions: [
                    TextButton(
                        onPressed: () {},
                        child: const Text('Restaurer les préférences'))
                  ],
                  children: [
                    SettingsGroup(title: 'Audio', children: [
                      SettingsTile(
                        icon: Icons.translate_rounded,
                        title: 'Langue audio par défaut',
                        subtitle:
                            'Choisie à l’ouverture du média lorsqu’une piste correspondante existe.',
                        trailing: OutlinedButton(
                          onPressed: () => actionCount++,
                          child: const Text('Français'),
                        ),
                      ),
                    ]),
                    SettingsGroup(title: 'Préférences de lecture', children: [
                      SettingsSwitchTile(
                        icon: Icons.skip_next_rounded,
                        title: 'Épisode suivant',
                        subtitle: 'Enchaîner automatiquement les épisodes.',
                        value: enabled,
                        onChanged: (value) => setState(() => enabled = value),
                      ),
                      SettingsChoiceTile<String>(
                        icon: Icons.memory_rounded,
                        title: 'Décodage vidéo',
                        subtitle: 'Choisissez le mode adapté à votre appareil.',
                        value: 'auto',
                        options: const [
                          ('auto', 'Automatique'),
                          ('hardware', 'Matériel'),
                          ('software', 'Logiciel')
                        ],
                        onChanged: (_) {},
                      ),
                    ]),
                    const SettingsGroup(
                        title: 'Appareils connectés',
                        children: [
                          SettingsEmptyNote('Aucun autre appareil connecté.',
                              icon: Icons.devices_outlined),
                        ]),
                  ],
                );
              }),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Français'));
      expect(actionCount, 1);
      await tester.tap(find.text('Épisode suivant'));
      await tester.pumpAndSettle();
      expect(enabled, isTrue);
      expect(tester.takeException(), isNull);

      // Large system text must also keep the controls reachable.
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
