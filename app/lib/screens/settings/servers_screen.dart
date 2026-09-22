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
///
/// Les liens entre comptes, eux, sont tenus par les serveurs (ADR-0017) : un
/// serveur lié depuis un autre appareil apparaît ici, et il suffit d'y entrer
/// son mot de passe une fois pour l'ajouter à cet appareil.
class ServersScreen extends StatefulWidget {
  const ServersScreen({super.key, this.embedded = false});

  /// Sans barre ni défilement propre, pour vivre dans une page des paramètres.
  final bool embedded;

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
    _refreshLinks();
  }

  Future<void> _refreshLinks() async {
    await context.read<ApiClient>().refreshAccountLinks();
    if (mounted) setState(() {});
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

  /// Désigne — ou libère — le serveur sur lequel l'app se remettra à chaque
  /// lancement. Un seul à la fois : c'est une place, pas une étiquette.
  Future<void> _togglePrimary(ServerAccount account) async {
    final auth = context.read<AuthProvider>();
    final wasPrimary = auth.isPrimaryServer(account.id);
    await auth.setPrimaryServer(wasPrimary ? null : account.id);
    if (!mounted) return;
    _toast(wasPrimary
        ? '${account.displayName} n’est plus le serveur principal.'
        : 'L’app démarrera sur ${account.displayName}.');
    setState(() {});
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
    final candidates = _linkCandidates(api, account);
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Lier ${account.username} à un compte'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Text(
                'Choisissez un autre de vos comptes. Les deux serveurs se transmettront votre progression, '
                'et chacun apparaîtra sur vos autres appareils. Les administrateurs des deux serveurs '
                'doivent accepter le lien une première fois.'),
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
    await linkAndReport(context, account.id, chosen);
    if (mounted) setState(() {});
  }

  Future<void> _unlink(ServerAccount account) async {
    final api = context.read<ApiClient>();
    final links = api.servers.serverLinksFor(account.id);
    if (links.isEmpty) return;
    final link = links.length == 1
        ? links.single
        : await showDialog<AccountLink>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: const Text('Dissocier quel compte ?'),
              children: [
                for (final link in links)
                  SimpleDialogOption(
                    onPressed: () => Navigator.of(ctx).pop(link),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child:
                          Text('${link.remoteUsername} · ${link.displayName}'),
                    ),
                  ),
                SimpleDialogOption(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Annuler'),
                ),
              ],
            ),
          );
    if (link == null || !mounted) return;
    try {
      await api.unlinkAccount(account.id, link);
      _toast('Compte dissocié. L’historique déjà partagé est conservé.');
    } catch (e) {
      _toast(_errorText(e), error: true);
    }
    if (mounted) setState(() {});
  }

  Future<void> _signInToLinked(AccountLink link) async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddServerScreen(
          initialUrl: link.url,
          initialUsername: link.remoteUsername,
          signIn: true,
        ),
      ),
    );
    if (added == true && mounted) setState(() {});
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
    final api = context.read<ApiClient>();
    final elsewhere = _serversNotOnThisDevice(api);

    final children = <Widget>[
      if (!widget.embedded) ...[
        const Text(
          'Liez vos comptes, même avec des noms différents : les serveurs se transmettent votre '
          'progression, vos serveurs vous suivent sur tous vos appareils, et la lecture reprend '
          'sur un serveur disponible.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 10),
        const Text(
          'Désignez un serveur principal pour que l’app y revienne à chaque lancement. '
          'S’il ne répond pas, elle vous proposera les autres au lieu de basculer toute seule.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 20),
      ],
      for (final account in accounts)
        _ServerTile(
          account: account,
          isActive: account.id == activeId,
          isPrimary: auth.isPrimaryServer(account.id),
          busy: auth.isLoading,
          onSelect: () => _switchTo(account),
          onTogglePrimary: () => _togglePrimary(account),
          onRename: () => _rename(account),
          links: api.servers.serverLinksFor(account.id),
          onLink: _linkCandidates(api, account).isNotEmpty
              ? () => _link(account)
              : null,
          onUnlink: () => _unlink(account),
          onForget: accounts.length == 1 ? null : () => _forget(account),
        ),
      if (elsewhere.isNotEmpty) ...[
        const SizedBox(height: 24),
        const Text(
          'Vos autres serveurs',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        const Text(
          'Liés à votre compte, mais pas encore ouverts sur cet appareil. '
          'Entrez votre mot de passe une fois pour pouvoir y basculer.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
        for (final link in elsewhere)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.dns_outlined),
            title: Text(link.displayName),
            subtitle: Text(
              link.remoteUsername,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            trailing: TextButton(
              onPressed: () => _signInToLinked(link),
              child: const Text('Se connecter'),
            ),
          ),
      ],
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
    ];

    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Serveurs')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: children,
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.account,
    required this.isActive,
    required this.isPrimary,
    required this.busy,
    required this.onSelect,
    required this.onTogglePrimary,
    required this.onRename,
    required this.links,
    required this.onLink,
    required this.onUnlink,
    required this.onForget,
  });

  final ServerAccount account;
  final bool isActive;

  /// Celui sur lequel l'app redémarre, marqué d'une étoile.
  final bool isPrimary;

  final bool busy;
  final VoidCallback onSelect;
  final VoidCallback onTogglePrimary;
  final VoidCallback onRename;
  final List<AccountLink> links;
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
          title: Row(
            children: [
              Flexible(child: Text(account.displayName)),
              if (isPrimary) ...[
                const SizedBox(width: 6),
                const Icon(
                  Icons.star_rounded,
                  size: 16,
                  color: AppColors.warning,
                ),
              ],
            ],
          ),
          subtitle: Text(
            '${account.username} · ${isActive ? 'serveur actif' : account.prettyHost}'
            '${isPrimary ? ' · serveur principal' : ''}'
            '${links.isEmpty ? '' : '\nLié à ${links.map((l) => '${l.remoteUsername} sur ${l.displayName}${l.isActive ? '' : ' (en attente des administrateurs)'}').join(', ')}'}',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          trailing: PopupMenuButton<String>(
            tooltip: 'Options du compte ${account.username}',
            enabled: !busy,
            onSelected: (value) {
              switch (value) {
                case 'primary':
                  onTogglePrimary();
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
              PopupMenuItem(
                value: 'primary',
                child: Text(isPrimary
                    ? 'Ne plus démarrer ici'
                    : 'Démarrer sur ce serveur'),
              ),
              if (onLink != null)
                const PopupMenuItem(
                    value: 'link', child: Text('Lier un compte')),
              if (links.isNotEmpty)
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
  const AddServerScreen({
    super.key,
    this.initialUrl,
    this.initialUsername,
    this.signIn = false,
  });

  /// Pré-remplis quand on vient d'un serveur lié à son compte : il ne reste
  /// que le mot de passe à taper.
  final String? initialUrl;
  final String? initialUsername;
  final bool signIn;

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

  late _AddMode _mode = widget.signIn ? _AddMode.signIn : _AddMode.request;
  bool _busy = false;
  bool _discovering = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _serverController.text = widget.initialUrl ?? '';
    _usernameController.text = widget.initialUsername ?? '';
  }

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

    final previous = auth.activeServer;
    try {
      if (_mode == _AddMode.signIn) {
        final account = await auth.addServerWithPassword(
          serverUrl: url,
          username: username,
          password: password,
        );
        if (!mounted) return;
        _snack('${account.displayName} ajouté.');
        if (previous != null && previous.id != account.id) {
          await _offerLink(previous, account);
        }
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

  /// Juste après l'ajout, le bon moment pour demander si c'est la même
  /// personne : sur un appareil partagé, ce n'est pas toujours le cas, donc
  /// rien n'est lié sans le demander.
  Future<void> _offerLink(ServerAccount previous, ServerAccount added) async {
    final api = context.read<ApiClient>();
    await api.refreshAccountLinks();
    if (!mounted ||
        api.servers.linkedAccounts(previous.id).any((a) => a.id == added.id)) {
      return;
    }
    final link = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title:
            Text('Lier à ${previous.username} sur ${previous.displayName} ?'),
        content: const Text(
          'Si ces deux comptes sont à vous, vos serveurs se transmettront votre '
          'progression et chacun apparaîtra sur vos autres appareils. Les '
          'administrateurs des deux serveurs doivent accepter le lien une '
          'première fois.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Plus tard'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Lier'),
          ),
        ],
      ),
    );
    if (link == true && mounted) {
      await linkAndReport(context, previous.id, added.id);
    }
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

/// Les autres comptes de cet appareil qu'on peut lier à [account] : sur un
/// autre serveur, et pas déjà liés.
List<ServerAccount> _linkCandidates(ApiClient api, ServerAccount account) {
  final linked =
      api.servers.linkedAccounts(account.id).map((a) => a.id).toSet();
  return api.servers.accounts
      .where((a) =>
          !linked.contains(a.id) &&
          a.url != account.url &&
          (a.serverId == null || a.serverId != account.serverId))
      .toList();
}

/// Les serveurs liés à un compte de cet appareil sur lesquels il n'a pas
/// encore de session, une fois chacun.
List<AccountLink> _serversNotOnThisDevice(ApiClient api) {
  final seen = <String>{};
  final result = <AccountLink>[];
  for (final account in api.servers.accounts) {
    for (final link in api.servers.serverLinksFor(account.id)) {
      if (api.servers.accountForLink(link) != null) continue;
      final key = link.serverId.isEmpty ? link.url : link.serverId;
      if (seen.add(key)) result.add(link);
    }
  }
  return result;
}

/// Lie deux comptes et dit où en est le lien.
Future<void> linkAndReport(
    BuildContext context, String fromId, String toId) async {
  final messenger = ScaffoldMessenger.of(context);
  final api = context.read<ApiClient>();
  try {
    final link = await api.linkAccounts(fromId, toId);
    messenger.showSnackBar(SnackBar(
      content: Text(link.isActive
          ? 'Comptes liés. Les serveurs se transmettent désormais votre progression.'
          : 'Lien demandé. Il sera actif dès que les administrateurs des deux serveurs l’auront accepté.'),
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(
      content: Text(_errorText(e)),
      backgroundColor: AppColors.error,
    ));
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
  if (error is StateError) return error.message;
  return 'Une erreur est survenue : $error';
}
