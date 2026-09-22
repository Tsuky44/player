import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/server_account.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';

/// Ce que l'app affiche quand le serveur principal ne répond pas au lancement.
///
/// Elle pourrait se rabattre toute seule sur un autre compte, ou ouvrir une
/// session hors ligne sans rien dire. Les deux sont des choix qu'elle n'a pas
/// à faire : désigner un serveur principal, c'est précisément dire « c'est
/// celui-là que je veux » — donc son absence se constate, elle ne se contourne
/// pas en silence. Voir ADR-0013 pour le carnet de comptes.
class ServerChoiceScreen extends StatefulWidget {
  const ServerChoiceScreen({super.key});

  @override
  State<ServerChoiceScreen> createState() => _ServerChoiceScreenState();
}

class _ServerChoiceScreenState extends State<ServerChoiceScreen> {
  /// Y a-t-il un profil en cache pour le principal ? Sans lui, « continuer
  /// hors ligne » ne mènerait qu'à l'écran de connexion : autant ne pas le
  /// proposer.
  bool _canGoOffline = false;

  @override
  void initState() {
    super.initState();
    _lookForCachedProfile();
  }

  Future<void> _lookForCachedProfile() async {
    final cached = await context.read<ApiClient>().readCachedProfile();
    if (!mounted || cached == null) return;
    setState(() => _canGoOffline = true);
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? AppColors.error : null,
    ));
  }

  Future<void> _retry() async {
    final auth = context.read<AuthProvider>();
    final primary = auth.unreachablePrimary;
    if (await auth.retryPrimaryServer() || !mounted) return;
    _toast(
      '${primary?.displayName ?? 'Le serveur principal'} ne répond toujours pas.',
      error: true,
    );
  }

  Future<void> _switchTo(ServerAccount account) async {
    final auth = context.read<AuthProvider>();
    if (await auth.switchServer(account.id) || !mounted) return;
    _toast(auth.errorMessage ?? 'Bascule impossible.', error: true);
  }

  Future<void> _stayOffline() async {
    final auth = context.read<AuthProvider>();
    if (await auth.continueOfflineOnPrimary() || !mounted) return;
    _toast('Rien n’a été gardé de ce serveur : reconnectez-vous.', error: true);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final primary = auth.unreachablePrimary;
    final others = [
      for (final account in auth.servers)
        if (account.id != primary?.id) account,
    ];

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
              children: [
                const Icon(
                  Icons.cloud_off_rounded,
                  size: 52,
                  color: AppColors.warning,
                ),
                const SizedBox(height: 20),
                Text(
                  'Serveur principal non disponible',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 10),
                Text(
                  '${primary?.displayName ?? 'Votre serveur'} ne répond pas. '
                  'Voulez-vous basculer sur un autre de vos serveurs ?',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 24),
                for (final account in others)
                  _ChoiceTile(
                    account: account,
                    busy: auth.isLoading,
                    onSelect: () => _switchTo(account),
                  ),
                if (others.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Aucun autre serveur n’est ouvert sur cet appareil.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: auth.isLoading ? null : _retry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(auth.isLoading ? 'Connexion…' : 'Réessayer'),
                ),
                if (_canGoOffline) ...[
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: auth.isLoading ? null : _stayOffline,
                    child: const Text('Continuer hors ligne'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Un serveur sur lequel basculer. Volontairement de la même famille que les
/// tuiles de l'écran des serveurs : c'est le même geste.
class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.account,
    required this.busy,
    required this.onSelect,
  });

  final ServerAccount account;
  final bool busy;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          onTap: busy ? null : onSelect,
          leading: CircleAvatar(
            backgroundColor: AppColors.primary.withValues(alpha: 0.16),
            child: const Icon(
              Icons.dns_rounded,
              size: 20,
              color: AppColors.textPrimary,
            ),
          ),
          title: Text(account.displayName),
          subtitle: Text(
            '${account.username} · ${account.prettyHost}',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
        ),
      ),
    );
  }
}
