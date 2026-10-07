import 'package:flutter/material.dart';

import '../../../services/client_identity.dart';
import '../legal_document_screen.dart';
import 'settings_ui.dart';
import '../../../l10n/tr.dart';

/// « À propos » : la version, puis tout ce qu'un magasin d'applications exige
/// de trouver dans l'app elle-même — politique de confidentialité, conditions,
/// licences des composants libres, attribution TMDB et rappel de qui répond du
/// contenu (ADR-0046).
class AboutGroup extends StatelessWidget {
  const AboutGroup({super.key});

  /// La formule imposée par les conditions de l'API TMDB, mot pour mot.
  static const String tmdbAttribution =
      'Ce produit utilise l’API TMDB mais n’est ni approuvé ni certifié '
          'par TMDB.';

  static const String responsibility =
      'Onyx ne fournit, n’héberge et ne vend aucun contenu. Vous êtes '
          'responsable de votre serveur, de vos fichiers et des droits '
          'associés.';

  void _open(BuildContext context, LegalDocument document) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LegalDocumentScreen(document: document),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SettingsGroup(
      title: tr('À propos'),
      footer: '${tr(responsibility)}\n${tr(tmdbAttribution)}',
      children: [
        SettingsTile(
          icon: Icons.info_outline_rounded,
          title: tr('Onyx {0}', [ClientIdentity.version]),
          subtitle: ClientIdentity.platform,
          showChevron: false,
        ),
        SettingsTile(
          icon: Icons.badge_outlined,
          title: ClientIdentity.deviceName,
          subtitle:
              tr('Le nom sous lequel cet appareil apparaît dans la liste '
                  'des appareils connectés.'),
          showChevron: false,
        ),
        SettingsTile(
          icon: Icons.privacy_tip_outlined,
          title: LegalDocument.privacy.title,
          onTap: () => _open(context, LegalDocument.privacy),
        ),
        SettingsTile(
          icon: Icons.gavel_rounded,
          title: LegalDocument.terms.title,
          onTap: () => _open(context, LegalDocument.terms),
        ),
        SettingsTile(
          icon: Icons.code_rounded,
          title: tr('Licences open source'),
          subtitle: tr('mpv, FFmpeg, AetherEngine, Flutter et les autres'),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Onyx',
            applicationVersion: ClientIdentity.version,
          ),
        ),
      ],
    );
  }
}
