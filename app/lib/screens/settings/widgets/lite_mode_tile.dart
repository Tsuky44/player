import 'package:flutter/material.dart';

import '../../../l10n/tr.dart';
import '../../../theme/lite_mode.dart';
import 'settings_ui.dart';

/// Le réglage du mode léger (ADR-0086) : « Auto » dit pourquoi il est actif,
/// pour qu'on comprenne d'où vient une interface sans flou.
class LiteModeTile extends StatefulWidget {
  const LiteModeTile({super.key});

  @override
  State<LiteModeTile> createState() => _LiteModeTileState();
}

class _LiteModeTileState extends State<LiteModeTile> {
  String _status() {
    switch (LiteMode.reason) {
      case LiteModeReason.hardware:
        return tr('Actif : cet appareil a peu de ressources.');
      case LiteModeReason.measured:
        return tr('Actif : l’interface saccadait sur cet appareil.');
      case LiteModeReason.chosen:
        return tr('Actif.');
      case LiteModeReason.none:
        return tr('Inactif.');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Lu pour être reconstruit quand la mesure des images l'active d'elle-même.
    LiteScope.of(context);
    return SettingsChoiceTile<LiteModePreference>(
      icon: Icons.speed_rounded,
      title: tr('Mode léger'),
      subtitle: tr(
        'Retire le flou, les mouvements et les ombres pour garder '
        'l’interface et la lecture fluides sur un petit appareil. '
        'Le fichier reste lu tel quel. {0}',
        [_status()],
      ),
      value: LiteMode.preference,
      options: [
        (LiteModePreference.auto, tr('Auto')),
        (LiteModePreference.on, tr('Activé')),
        (LiteModePreference.off, tr('Désactivé')),
      ],
      onChanged: (value) async {
        await LiteMode.setPreference(value);
        if (mounted) setState(() {});
      },
    );
  }
}
