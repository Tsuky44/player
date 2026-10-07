import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/otp.dart';
import '../../services/api_client.dart';
import 'widgets/settings_ui.dart';
import '../../l10n/tr.dart';

/// La politique de validation en deux étapes du serveur (ADR-0041), réglée
/// par un titulaire de `manage_settings`.
class OtpPolicyGroup extends StatefulWidget {
  const OtpPolicyGroup({super.key});

  @override
  State<OtpPolicyGroup> createState() => _OtpPolicyGroupState();
}

class _OtpPolicyGroupState extends State<OtpPolicyGroup> {
  OtpPolicy? _policy;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = await context.read<ApiClient>().getServerSettings();
      if (!mounted) return;
      setState(() {
        _policy = settings.otpPolicy;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          settingsErrorText(e, tr('Impossible de lire la politique du serveur.')));
    }
  }

  Future<void> _change(OtpPolicy next) async {
    final previous = _policy;
    if (_saving || next == previous) return;
    if (next == OtpPolicy.disabled) {
      final confirmed = await confirmSettingsAction(
        context,
        title: tr('Désactiver la validation en deux étapes ?'),
        message:
            tr('Plus aucun code ne sera demandé, même aux comptes qui en '
                'ont configuré un : le mot de passe suffira. Les codes '
                'configurés reviendront si vous la réactivez.'),
        confirmLabel: tr('Désactiver'),
      );
      if (!confirmed || !mounted) return;
    }
    // Optimiste : la réponse du serveur tranche, et un refus remet l'ancienne.
    setState(() {
      _policy = next;
      _saving = true;
    });
    try {
      final saved =
          await context.read<ApiClient>().updateServerSettings(otpPolicy: next);
      if (!mounted) return;
      setState(() {
        _policy = saved.otpPolicy;
        _saving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _policy = previous;
        _saving = false;
      });
      showSettingsSnack(context, settingsErrorText(e, tr('Enregistrement impossible.')),
          error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final policy = _policy;
    return SettingsGroup(
      title: tr('Validation en deux étapes'),
      footer:
          tr('Une obligation s’applique à la connexion suivante de chaque '
              'compte concerné : il configure alors son code avant d’entrer. '
              'Les appareils déjà connectés le restent. Les administrateurs '
              'sont les comptes qui gèrent les paramètres, la bibliothèque '
              'ou les utilisateurs.'),
      children: [
        if (_error != null)
          SettingsEmptyNote(_error!, icon: Icons.error_outline)
        else if (policy == null)
          const SettingsLoading()
        else
          SettingsChoiceTile<OtpPolicy>(
            icon: Icons.phonelink_lock_rounded,
            title: tr('Exiger un code'),
            subtitle: _describe(policy),
            value: policy,
            options: [for (final p in OtpPolicy.values) (p, p.label)],
            onChanged: _change,
          ),
      ],
    );
  }

  String _describe(OtpPolicy policy) => switch (policy) {
        OtpPolicy.disabled =>
          tr('Personne ne peut l’activer, et le mot de passe suffit toujours.'),
        OtpPolicy.optional => tr('Chaque compte l’active s’il le souhaite.'),
        OtpPolicy.admins =>
          tr('Imposée aux administrateurs, facultative pour les autres comptes.'),
        OtpPolicy.everyone => tr('Imposée à tous les comptes.'),
      };
}
