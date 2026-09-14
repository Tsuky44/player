import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/server_account.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_deferred_keyboard.dart';

/// Les serveurs liés à celui-ci (ADR-0017).
///
/// Une paire de serveurs n'a cours qu'une fois acceptée par un administrateur
/// de chaque côté, et une seule fois : les comptes liés ensuite entre ces deux
/// mêmes serveurs n'ont plus à attendre personne. Accepter, c'est permettre aux
/// deux serveurs de se transmettre la progression des comptes que leurs
/// propriétaires ont liés.
class LinkedServersSection extends StatefulWidget {
  const LinkedServersSection({super.key});

  @override
  State<LinkedServersSection> createState() => _LinkedServersSectionState();
}

class _LinkedServersSectionState extends State<LinkedServersSection> {
  List<PeerServer> _peers = const [];
  bool _loading = true;
  String? _error;
  int? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final peers = await context.read<ApiClient>().getPeerServers();
      if (!mounted) return;
      setState(() {
        _peers = peers;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _errorText(e);
      });
    }
  }

  Future<void> _run(PeerServer peer, Future<void> Function() action) async {
    setState(() => _busyId = peer.id);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_errorText(e)),
          backgroundColor: AppColors.error,
        ));
      }
    }
    if (!mounted) return;
    setState(() => _busyId = null);
    await _load();
  }

  Future<void> _remove(PeerServer peer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(peer.isActive || peer.localApproved
            ? 'Retirer ${_name(peer)} ?'
            : 'Refuser ${_name(peer)} ?'),
        content: const Text(
          'Les deux serveurs cessent de se transmettre la progression et les '
          'comptes liés entre eux sont dissociés. L’historique déjà partagé '
          'reste sur chaque serveur.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Confirmer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(peer, () => context.read<ApiClient>().removePeerServer(peer.id));
  }

  Future<void> _editUrl(PeerServer peer) async {
    final controller = TextEditingController(text: peer.url);
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Adresse du serveur lié'),
        content: TvDeferredKeyboard(
          builder: (context, focusNode, canRequestFocus) => TextField(
            focusNode: focusNode,
            canRequestFocus: canRequestFocus,
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Adresse joignable depuis ce serveur',
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
    if (url == null || url.trim().isEmpty || !mounted) return;
    await _run(peer,
        () => context.read<ApiClient>().updatePeerServerUrl(peer.id, url));
  }

  String _name(PeerServer peer) =>
      peer.name.trim().isEmpty ? peer.url : peer.name.trim();

  String _status(PeerServer peer) {
    final accounts =
        '${peer.accounts} compte${peer.accounts > 1 ? 's' : ''} lié${peer.accounts > 1 ? 's' : ''}';
    if (peer.isActive) return 'Lié · $accounts';
    if (!peer.localApproved) return 'Demande de lien · $accounts';
    return 'En attente de l’administrateur de l’autre serveur · $accounts';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: AppColors.error)),
          const SizedBox(height: 12),
        ],
        if (_peers.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              'Aucun serveur lié. Une demande apparaît ici quand un utilisateur '
              'lie son compte à un compte d’un autre serveur.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
        for (final peer in _peers)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              peer.isActive ? Icons.link_rounded : Icons.link_off_rounded,
              color: peer.isActive ? AppColors.primary : null,
            ),
            title: Text(_name(peer)),
            subtitle: Text(
              [
                peer.url,
                _status(peer),
                if (peer.lastError.isNotEmpty) peer.lastError,
              ].join('\n'),
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            isThreeLine: true,
            trailing: _busyId == peer.id
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!peer.localApproved) ...[
                        IconButton(
                          tooltip: 'Refuser le lien',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => _remove(peer),
                        ),
                        IconButton(
                          tooltip: 'Autoriser le lien',
                          icon: const Icon(Icons.check_rounded),
                          onPressed: () => _run(
                              peer,
                              () => context
                                  .read<ApiClient>()
                                  .approvePeerServer(peer.id)),
                        ),
                      ],
                      PopupMenuButton<String>(
                        tooltip: 'Options de ${_name(peer)}',
                        onSelected: (value) {
                          if (value == 'url') _editUrl(peer);
                          if (value == 'remove') _remove(peer);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'url', child: Text('Modifier l’adresse')),
                          PopupMenuItem(
                              value: 'remove', child: Text('Retirer le lien')),
                        ],
                      ),
                    ],
                  ),
          ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Actualiser'),
          ),
        ),
      ],
    );
  }
}

String _errorText(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['error'] != null) return data['error'].toString();
  }
  return 'Une erreur est survenue : $error';
}
