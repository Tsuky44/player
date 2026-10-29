import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/tr.dart';
import '../../models/my_request.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../utils/external_url.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/empty_state.dart';
import '../../widgets/global/staggered_entrance.dart';
import 'request_detail_screen.dart';
import 'widgets/my_request_card.dart';
import 'widgets/request_moderation_dialogs.dart';

/// Les demandes du compte et leur avancement, lues chez MediaHub (ADR-0073,
/// ADR-0087) : ce que l'onglet Demander envoie, on le retrouve ici jusqu'à ce
/// que ce soit disponible. Un compte que MediaHub laisse lire toutes les
/// demandes voit aussi celles des autres, et les modère s'il en a le droit.
class MyRequestsScreen extends StatefulWidget {
  const MyRequestsScreen({super.key});

  @override
  State<MyRequestsScreen> createState() => _MyRequestsScreenState();
}

enum _Scope { mine, all }

class _MyRequestsScreenState extends State<MyRequestsScreen> {
  late Future<List<MyRequest>> _requests;
  RequestAccess _access = RequestAccess.basic;
  _Scope _scope = _Scope.mine;

  /// Le lot dont une décision part, par son premier identifiant.
  int? _moderating;

  /// Le serveur sait ouvrir MediaHub déjà connecté (ADR-0088).
  bool _canOpenHub = false;
  bool _openingHub = false;

  @override
  void initState() {
    super.initState();
    _requests = _load();
    _loadAccess();
  }

  Future<List<MyRequest>> _load() {
    final api = context.read<ApiClient>();
    return _scope == _Scope.all ? api.getAllRequests() : api.getMyRequests();
  }

  Future<void> _loadAccess() async {
    final api = context.read<ApiClient>();
    try {
      final access = await api.getRequestAccess();
      if (mounted) setState(() => _access = access);
    } catch (error) {
      // Sans les droits, l'écran reste celui des seules demandes du compte.
      debugPrint('MyRequestsScreen: droits illisibles ($error)');
    }
    try {
      final canOpen = await api.supportsMediaHubSso();
      if (mounted) setState(() => _canOpenHub = canOpen);
    } catch (error) {
      // Sans réponse, le bouton reste caché : rien d'autre n'en dépend.
      debugPrint('MyRequestsScreen: SSO MediaHub inconnu ($error)');
    }
  }

  /// Ouvre MediaHub dans le navigateur, connecté au compte Onyx. Le code ne
  /// vaut qu'une minute : il se tire au clic, jamais à l'avance.
  Future<void> _openHub() async {
    final api = context.read<ApiClient>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _openingHub = true);
    try {
      final ticket = await api.openMediaHubTicket();
      if (await openExternalUrl(ticket.url)) return;
      // Le mobile ne sait pas confier une adresse au navigateur : elle passe
      // par le presse-papiers.
      await Clipboard.setData(ClipboardData(text: ticket.url));
      messenger.showSnackBar(SnackBar(
          content: Text(tr('Lien copié : ouvrez-le dans votre navigateur '
              'dans la minute.'))));
    } catch (error) {
      debugPrint('MyRequestsScreen: MediaHub pas ouvert ($error)');
      messenger.showSnackBar(SnackBar(
          content: Text(
              _errorText(error, tr('Impossible d’ouvrir MediaHub.')))));
    } finally {
      if (mounted) setState(() => _openingHub = false);
    }
  }

  Future<void> _reload() async {
    final next = _load();
    // Un bloc, pas une flèche : la flèche rendrait le Future affecté, et
    // setState refuse une fonction qui rend un Future.
    setState(() {
      _requests = next;
    });
    try {
      await next;
    } catch (_) {
      // L'échec s'affiche par le FutureBuilder, avec « Réessayer ».
    }
  }

  void _switchScope(_Scope scope) {
    if (scope == _scope) return;
    _scope = scope;
    _reload();
  }

  String _errorText(Object? error, String fallback) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['error'] is String) {
        return data['error'] as String;
      }
    }
    return fallback;
  }

  Future<void> _moderate(MyRequest request, RequestModeration action) async {
    String? reason;
    if (action == RequestModeration.decline) {
      reason = await askDeclineReason(context, request.title);
      if (reason == null) return;
    } else if (action == RequestModeration.delete) {
      if (!await confirmDeleteRequest(context, request.title)) return;
    }
    if (!mounted) return;
    final api = context.read<ApiClient>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _moderating = request.requestIds.first);
    try {
      await api.moderateRequests(request.requestIds, action, reason: reason);
      messenger.showSnackBar(SnackBar(
          content: Text(switch (action) {
        RequestModeration.approve => tr('Demande approuvée.'),
        RequestModeration.decline => tr('Demande refusée.'),
        RequestModeration.delete => tr('Demande supprimée.'),
      })));
      await _reload();
    } catch (error) {
      debugPrint('MyRequestsScreen: modération refusée ($error)');
      messenger.showSnackBar(SnackBar(
          content: Text(
              _errorText(error, tr('MediaHub n’a pas pris la décision.')))));
    } finally {
      if (mounted) setState(() => _moderating = null);
    }
  }

  MyRequestActions _actionsFor(MyRequest request) {
    if (_scope != _Scope.all || request.requestIds.isEmpty) {
      return const MyRequestActions();
    }
    final decides = _access.canModerate && request.awaitsDecision;
    return MyRequestActions(
      onApprove: decides
          ? () => _moderate(request, RequestModeration.approve)
          : null,
      onDecline: decides
          ? () => _moderate(request, RequestModeration.decline)
          : null,
      onDelete: _access.canDelete
          ? () => _moderate(request, RequestModeration.delete)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final padding = AppLayout.pagePadding(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
            _scope == _Scope.all ? tr('Toutes les demandes') : tr('Mes demandes')),
        actions: [
          if (_canOpenHub && _access.service == 'mediahub')
            IconButton(
              tooltip: tr('Ouvrir MediaHub'),
              icon: const Icon(AppIcons.openInBrowser),
              onPressed: _openingHub ? null : _openHub,
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_access.canReadAll)
            Padding(
              padding: EdgeInsets.fromLTRB(padding, 8, padding, 0),
              child: Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: Text(tr('Les miennes')),
                    selected: _scope == _Scope.mine,
                    onSelected: (_) => _switchScope(_Scope.mine),
                  ),
                  ChoiceChip(
                    label: Text(tr('Tous les comptes')),
                    selected: _scope == _Scope.all,
                    onSelected: (_) => _switchScope(_Scope.all),
                  ),
                ],
              ),
            ),
          if (!_access.linked && _scope == _Scope.mine)
            Padding(
              padding: EdgeInsets.fromLTRB(padding, 12, padding, 0),
              child: Text(
                tr('MediaHub n’a pas de compte à votre nom : vos demandes '
                    'partent, mais ne se retrouvent pas ici.'),
                style: const TextStyle(color: AppColors.textMuted),
              ),
            ),
          Expanded(child: _list(padding)),
        ],
      ),
    );
  }

  Widget _list(double padding) {
    return FutureBuilder<List<MyRequest>>(
      future: _requests,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const LoadingView();
        }
        if (snapshot.hasError) {
          return ErrorStateView(
              message: _errorText(
                  snapshot.error, tr('Impossible de charger vos demandes.')),
              onRetry: _reload);
        }
        final requests = snapshot.data ?? const [];
        if (requests.isEmpty) {
          return EmptyStateView(
            icon: AppIcons.request,
            title: tr('Aucune demande'),
            message: _scope == _Scope.all
                ? tr('Aucun compte n’a encore rien demandé.')
                : tr('Ce que vous demandez depuis l’onglet Demander '
                    'apparaît ici, avec son avancement.'),
          );
        }
        return RefreshIndicator(
          onRefresh: _reload,
          child: StaggeredEntranceScope(
            playKey: requests,
            maxAnimated: 8,
            child: ListView.separated(
              scrollCacheExtent: AppLayout.imageCacheExtent(context),
              padding: EdgeInsets.fromLTRB(padding, 12, padding, 32),
              itemCount: requests.length,
              separatorBuilder: (_, __) => const SizedBox(height: 14),
              itemBuilder: (context, index) {
                final request = requests[index];
                return StaggeredEntrance(
                  index: index,
                  child: MyRequestCard(
                    request: request,
                    showRequester: _scope == _Scope.all,
                    actions: _actionsFor(request),
                    busy: _moderating != null &&
                        request.requestIds.isNotEmpty &&
                        request.requestIds.first == _moderating,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            RequestDetailScreen(item: request.toRequestItem()))),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
