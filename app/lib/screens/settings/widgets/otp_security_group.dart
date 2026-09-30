import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/otp.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/global/otp_code_dialog.dart';
import '../user_admin_sections.dart' show promptPassword;
import 'settings_ui.dart';

/// La validation en deux étapes du compte connecté (ADR-0041) : l'activer, en
/// tirer de nouveaux codes de secours, la désactiver quand la politique du
/// serveur le permet.
class OtpSecurityGroup extends StatefulWidget {
  const OtpSecurityGroup({super.key});

  @override
  State<OtpSecurityGroup> createState() => _OtpSecurityGroupState();
}

class _OtpSecurityGroupState extends State<OtpSecurityGroup> {
  OtpStatus? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final status = await context.read<ApiClient>().getOtpStatus();
      if (!mounted) return;
      setState(() {
        _status = status;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = settingsErrorText(
          e, 'Impossible de lire l’état de la validation en deux étapes.'));
    }
  }

  Future<void> _enable() async {
    final api = context.read<ApiClient>();
    final OtpSetup setup;
    try {
      setup = await api.startOtpSetup();
    } catch (e) {
      if (mounted) {
        showSettingsSnack(context, settingsErrorText(e, 'Activation impossible.'),
            error: true);
      }
      return;
    }
    if (!mounted) return;
    final codes = await showOtpCodeDialog<List<String>>(
      context,
      title: 'Activer la validation en deux étapes',
      setup: setup,
      verify: api.enableOtp,
      recoveryCodesOf: (codes) => codes,
    );
    if (codes == null || !mounted) return;
    showSettingsSnack(context, 'Validation en deux étapes activée.');
    _afterChange();
  }

  Future<void> _regenerate() async {
    final password = await promptPassword(
      context,
      title: 'Nouveaux codes de secours',
      label: 'Mot de passe',
      hint: 'Les anciens codes ne fonctionneront plus.',
    );
    if (password == null || !mounted) return;
    try {
      final codes =
          await context.read<ApiClient>().regenerateOtpRecoveryCodes(password);
      if (!mounted) return;
      await showRecoveryCodesDialog(context, codes);
      _load();
    } catch (e) {
      if (mounted) {
        showSettingsSnack(context, settingsErrorText(e, 'Échec.'), error: true);
      }
    }
  }

  Future<void> _disable() async {
    final password = await promptPassword(
      context,
      title: 'Désactiver la validation en deux étapes',
      label: 'Mot de passe',
      hint: 'Le mot de passe suffira de nouveau pour vous connecter.',
    );
    if (password == null || !mounted) return;
    try {
      await context.read<ApiClient>().disableOtp(password);
      if (!mounted) return;
      showSettingsSnack(context, 'Validation en deux étapes désactivée.');
      _afterChange();
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, 'Désactivation impossible.'),
            error: true);
      }
    }
  }

  /// Le profil porte aussi l'état (la liste des comptes l'affiche) : il se
  /// relit avec lui.
  void _afterChange() {
    _load();
    context.read<AuthProvider>().refreshProfile();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return SettingsGroup(
      title: 'Validation en deux étapes',
      footer: status != null && status.required
          ? 'Obligatoire pour ce compte sur ce serveur.'
          : 'Un code de votre téléphone s’ajoute au mot de passe à chaque connexion.',
      children: [
        if (_error != null)
          SettingsEmptyNote(_error!, icon: Icons.error_outline)
        else if (status == null)
          const SettingsLoading()
        else if (status.policy == OtpPolicy.disabled) ...[
          const SettingsTile(
            icon: Icons.phonelink_lock_rounded,
            title: 'Indisponible',
            subtitle: 'Un administrateur l’a désactivée sur ce serveur.',
            showChevron: false,
          ),
          // Le code configuré reste en base et reviendrait avec la politique :
          // son titulaire peut le retirer d'ici.
          if (status.enabled)
            SettingsTile(
              icon: Icons.no_encryption_gmailerrorred_rounded,
              title: 'Supprimer mon code',
              subtitle:
                  'Sinon, il vous sera redemandé si la validation est réactivée.',
              destructive: true,
              showChevron: false,
              onTap: _disable,
            ),
        ] else if (!status.enabled)
          SettingsTile(
            icon: Icons.phonelink_lock_rounded,
            title: 'Activer',
            subtitle: status.required
                ? 'Elle vous sera demandée à la prochaine connexion si vous ne l’activez pas maintenant.'
                : 'Avec Google Authenticator, Aegis, 1Password…',
            onTap: _enable,
          )
        else ...[
          SettingsTile(
            icon: Icons.verified_user_rounded,
            iconColor: AppColors.success,
            title: 'Activée',
            subtitle: status.recoveryCodesLeft == 1
                ? '1 code de secours restant'
                : '${status.recoveryCodesLeft} codes de secours restants',
            showChevron: false,
          ),
          SettingsTile(
            icon: Icons.key_rounded,
            title: 'Nouveaux codes de secours',
            subtitle: 'Remplace les codes que vous avez notés.',
            onTap: _regenerate,
          ),
          if (!status.required)
            SettingsTile(
              icon: Icons.no_encryption_gmailerrorred_rounded,
              title: 'Désactiver',
              destructive: true,
              showChevron: false,
              onTap: _disable,
            ),
        ],
      ],
    );
  }
}
