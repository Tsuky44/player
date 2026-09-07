import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/server_account.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_client.dart';
import '../../services/server_discovery.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_deferred_keyboard.dart';

/// Les serveurs de cet appareil : celui qui est actif, ceux sur lesquels on
/// peut basculer, et les demandes d'accès encore sans réponse.
///
/// Basculer ne renégocie rien — chaque compte garde son jeton — donc l'écran
/// n'a pas de formulaire de connexion : ce sont des comptes déjà ouverts. Voir
/// ADR-0013.
class ServersScreen extends StatefulWidget {
  const ServersScreen({super.key});

  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends State<ServersScreen> {
  /// Le sondage des demandes en attente pendant que l'écran est ouvert. C'est
  /// exactement le moment où quelqu'un regarde si on lui a répondu.
  Timer? _poll;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _checkPending();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _checkPending());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _checkPending() async {
    if (_checking || !mounted) return;
    final auth = context.read<AuthProvider>();
    if (auth.pendingAccessRequests.isEmpty) return;
    _checking = true;
    final before = auth.pendingAccessRequests.length;
    await auth.refreshAccessRequests();
    _checking = false;
    if (!mounted || auth.pendingAccessRequests.length == before) return;
    _toast('Une demande d’accès a reçu une réponse.');
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? AppColors.error : null,
    ));
  }

  Future<void> _switchTo(ServerAccount account) async {
    final auth = context.read<AuthProvider>();
    final ok = await auth.switchServer(account.id);
    if (!mounted) return;
    if (ok) {
      _toast('Vous êtes sur ${account.displayName}.');
      Navigator.of(context).pop();
    } else {
      _toast(auth.errorMessage ?? 'Bascule impossible.', error: true);
    }
  }

  Future<void> _rename(ServerAccount account) async {
    final controller = TextEditingController(text: account.label ?? '');
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Nom du serveur'),
        content: TvDeferredKeyboard(
          builder: (context, focusNode, canRequestFocus) => TextField(
            focusNode: focusNode,
            canRequestFocus: canRequestFocus,
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Nom affiché',
              hintText: account.prettyHost,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (label == null || !mounted) return;
    await context.read<ApiClient>().servers.rename(account.id, label);
    if (mounted) setState(() {});
  }

  Future<void> _link(ServerAccount account) async {
    final api = context.read<ApiClient>();
    final linked =
        api.servers.linkedAccounts(account.id).map((a) => a.id).toSet();
    final candidates =
        api.servers.accounts.where((a) => !linked.contains(a.id)).toList();
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Lier ${account.username} à un compte'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Text(
                'Choisissez un autre de vos comptes. Les comptes liés partagent leur historique de lecture et prennent le relais si un serveur est indisponible et possède le même média.'),
          ),
          for (final other in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(other.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('${other.username} · ${other.displayName}'),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Annuler'),
          ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    await api.servers.linkAccounts(account.id, chosen);
    unawaited(api.synchronizeLinkedProgress());
    if (mounted) setState(() {});
    _toast('Comptes liés. La progression se synchronise automatiquement.');
  }

  Future<void> _unlink(ServerAccount account) async {
    await context.read<ApiClient>().servers.unlinkAccount(account.id);
    if (mounted) setState(() {});
    _toast('Compte dissocié. L’historique déjà partagé est conservé.');
  }

  Future<void> _forget(ServerAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Retirer ${account.displayName} ?'),
        content: const Text(
          'Ce serveur disparaît de cet appareil et il faudra retaper un mot de '
          'passe pour y revenir. Le compte lui-même n’est pas supprimé.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Retirer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<AuthProvider>().forgetServer(account.id);
    if (mounted) setState(() {});
  }

  Future<void> _addServer() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const AddServerScreen()),
    );
    if (added == true && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final accounts = auth.servers;
    final activeId = auth.activeServer?.id;
    final pending = auth.pendingAccessRequests;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Serveurs')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          const Text(
            'Sur cet appareil, liez vos comptes, même avec des noms différents, pour partager votre '
            'progression et reprendre automatiquement sur un serveur disponible.',
            style:
                TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 20),
          for (final account in accounts)
            _ServerTile(
              account: account,
              isActive: account.id == activeId,
              busy: auth.isLoading,
              onSelect: () => _switchTo(account),
              onRename: () => _rename(account),
              linked: context
                  .read<ApiClient>()
                  .servers
                  .linkedAccounts(account.id)
                  .where((a) => a.id != account.id)
                  .toList(),
              onLink: context
                          .read<ApiClient>()
                          .servers
                          .linkedAccounts(account.id)
                          .length <
                      accounts.length
                  ? () => _link(account)
                  : null,
              onUnlink: () => _unlink(account),
              onForget: accounts.length == 1 ? null : () => _forget(account),
            ),
          if (pending.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Text(
              'Demandes en attente',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              'Un administrateur du serveur doit accepter. La réponse est '
              'récupérée toute seule, y compris après un redémarrage de l’app.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
            for (final request in pending)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const SizedBox(
                  width: 24,
                  height: 24,
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
                title: Text(request.prettyHost),
                subtitle: Text(
                  'En attente · ${request.username}',
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                trailing: IconButton(
                  tooltip: 'Abandonner',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () async {
                    await context
                        .read<AuthProvider>()
                        .abandonAccessRequest(request);
                    if (mounted) setState(() {});
                  },
                ),
              ),
          ],
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _addServer,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Ajouter un serveur'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.account,
    required this.isActive,
    required this.busy,
    required this.onSelect,
    required this.onRename,
    required this.linked,
    required this.onLink,
    required this.onUnlink,
    required this.onForget,
  });

  final ServerAccount account;
  final bool isActive;
  final bool busy;
  final VoidCallback onSelect;
  final VoidCallback onRename;
  final List<ServerAccount> linked;
  final VoidCallback? onLink;
  final VoidCallback onUnlink;
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context) {
    // Le fond est porté par un Material et non par un DecoratedBox : sinon il
    // se peint par-dessus l'onde de la tuile, et toucher un serveur ne donne
    // aucun retour visible — précisément sur le geste dont tout dépend ici.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: isActive
            ? AppColors.primary.withValues(alpha: 0.10)
            : AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: isActive
                ? AppColors.primary.withValues(alpha: 0.45)
                : Colors.transparent,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          onTap: isActive || busy ? null : onSelect,
          leading: CircleAvatar(
            backgroundColor: AppColors.primary.withValues(alpha: 0.16),
            child: Icon(
              isActive ? Icons.check_rounded : Icons.dns_rounded,
              size: 20,
              color: AppColors.textPrimary,
            ),
          ),
          title: Text(account.displayName),
          subtitle: Text(
            '${account.username} · ${isActive ? 'serveur actif' : account.prettyHost}'
            '${linked.isEmpty ? '' : '\nLié à ${linked.map((a) => '${a.username} sur ${a.displayName}').join(', ')}'}',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          trailing: PopupMenuButton<String>(
            tooltip: 'Options du compte ${account.username}',
            enabled: !busy,
            onSelected: (value) {
              switch (value) {
                case 'link':
                  onLink?.call();
                case 'unlink':
                  onUnlink();
                case 'rename':
                  onRename();
                case 'forget':
                  onForget?.call();
              }
            },
            itemBuilder: (_) => [
              if (onLink != null)
                const PopupMenuItem(
                    value: 'link', child: Text('Lier un compte')),
              if (linked.isNotEmpty)
                const PopupMenuItem(
                    value: 'unlink', child: Text('Dissocier ce compte')),
              const PopupMenuItem(value: 'rename', child: Text('Renommer')),
              if (onForget != null)
                const PopupMenuItem(
                  value: 'forget',
                  child: Text('Retirer de cet appareil'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ajoute un serveur : soit on y a déjà un compte, soit on demande à y entrer.
///
/// Les deux chemins sont sur le même écran parce que la personne, elle, ne sait
/// pas toujours lequel la concerne avant d'avoir tapé l'adresse.
class AddServerScreen extends StatefulWidget {
  const AddServerScreen({super.key});

  @override
  State<AddServerScreen> createState() => _AddServerScreenState();
}

enum _AddMode { signIn, request }

class _AddServerScreenState extends State<AddServerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _messageController = TextEditingController();

  _AddMode _mode = _AddMode.request;
  bool _busy = false;
  bool _discovering = false;
  String? _error;

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    if (_discovering) return;
    setState(() => _discovering = true);
    String? found;
    try {
      found = await ServerDiscovery.find();
    } catch (_) {
      found = null;
    }
    if (!mounted) return;
    final address = found;
    setState(() {
      _discovering = false;
      if (address != null) _serverController.text = address;
    });
    if (found == null) _snack('Aucun serveur Onyx trouvé sur ce réseau.');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    final auth = context.read<AuthProvider>();
    final url = _serverController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      if (_mode == _AddMode.signIn) {
        final account = await auth.addServerWithPassword(
          serverUrl: url,
          username: username,
          password: password,
        );
        if (!mounted) return;
        _snack('${account.displayName} ajouté.');
      } else {
        await auth.requestAccess(
          serverUrl: url,
          username: username,
          password: password,
          message: _messageController.text.trim(),
        );
        if (!mounted) return;
        _snack(
            'Demande envoyée. Vous serez connecté dès qu’elle sera acceptée.');
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _errorText(e);
      });
      return;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final requesting = _mode == _AddMode.request;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Ajouter un serveur')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            SegmentedButton<_AddMode>(
              segments: const [
                ButtonSegment(
                  value: _AddMode.request,
                  label: Text('Demander l’accès'),
                  icon: Icon(Icons.doorbell_outlined, size: 18),
                ),
                ButtonSegment(
                  value: _AddMode.signIn,
                  label: Text('J’ai un compte'),
                  icon: Icon(Icons.login_rounded, size: 18),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: _busy
                  ? null
                  : (selection) => setState(() => _mode = selection.first),
            ),
            const SizedBox(height: 14),
            Text(
              requesting
                  ? 'Choisissez l’identifiant et le mot de passe que vous aurez '
                      'sur ce serveur. Le compte n’est créé qu’une fois la '
                      'demande acceptée.'
                  : 'Entrez les identifiants de votre compte sur ce serveur. '
                      'Votre serveur actuel n’est pas touché.',
              style:
                  const TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 20),
            TvDeferredKeyboard(
              builder: (context, focusNode, canRequestFocus) => TextFormField(
                focusNode: focusNode,
                canRequestFocus: canRequestFocus,
                controller: _serverController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Adresse du serveur',
                  hintText: 'http://192.168.1.50:8080',
                  prefixIcon: Icon(Icons.dns_rounded),
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Requis' : null,
              ),
            ),
            if (ServerDiscovery.isSupported)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _discovering ? null : _discover,
                  icon: _discovering
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.travel_explore_rounded, size: 18),
                  label: Text(_discovering
                      ? 'Recherche…'
                      : 'Détecter le serveur sur le réseau'),
                ),
              ),
            const SizedBox(height: 12),
            TvDeferredKeyboard(
              builder: (context, focusNode, canRequestFocus) => TextFormField(
                focusNode: focusNode,
                canRequestFocus: canRequestFocus,
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: 'Nom d’utilisateur',
                  prefixIcon: Icon(Icons.person_outline_rounded),
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Requis' : null,
              ),
            ),
            const SizedBox(height: 12),
            TvDeferredKeyboard(
              builder: (context, focusNode, canRequestFocus) => TextFormField(
                focusNode: focusNode,
                canRequestFocus: canRequestFocus,
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Mot de passe',
                  prefixIcon: Icon(Icons.lock_outline_rounded),
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Requis';
                  if (v.length < 4) return 'Minimum 4 caractères';
                  return null;
                },
              ),
            ),
            if (requesting) ...[
              const SizedBox(height: 12),
              TvDeferredKeyboard(
                builder: (context, focusNode, canRequestFocus) => TextFormField(
                  focusNode: focusNode,
                  canRequestFocus: canRequestFocus,
                  controller: _messageController,
                  maxLength: 280,
                  decoration: const InputDecoration(
                    labelText: 'Message (facultatif)',
                    hintText: 'Dites qui vous êtes',
                    prefixIcon: Icon(Icons.chat_bubble_outline_rounded),
                  ),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: AppColors.error.withValues(alpha: 0.35)),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppColors.error, fontSize: 13),
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(requesting ? 'Envoyer la demande' : 'Ajouter'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Message d'erreur lisible : le serveur en écrit un français, sinon on parle
/// de réseau.
String _errorText(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['error'] != null) return data['error'].toString();
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Le serveur ne répond pas (délai dépassé).';
      case DioExceptionType.connectionError:
        return 'Serveur injoignable. Vérifiez l’adresse et le réseau.';
      default:
        break;
    }
  }
  return 'Une erreur est survenue : $error';
}
