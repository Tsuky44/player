import 'package:flutter/material.dart';

import '../linked_servers_section.dart';
import '../widgets/settings_ui.dart';
import '../../../l10n/tr.dart';

/// Les serveurs liés à celui-ci (ADR-0017).
class LinkedServersPage extends StatelessWidget {
  const LinkedServersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: tr('Serveurs liés'),
      description:
          tr('Autoriser un lien permet à deux serveurs de se transmettre la '
              'progression des comptes que leurs utilisateurs ont liés. À '
              'accepter une fois par serveur, de chaque côté.'),
      children: [
        SettingsGroup(
          title: tr('Serveurs'),
          padded: true,
          children: [LinkedServersSection()],
        ),
      ],
    );
  }
}
