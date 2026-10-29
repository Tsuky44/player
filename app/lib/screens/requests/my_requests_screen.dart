import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/tr.dart';
import '../../models/my_request.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/empty_state.dart';
import '../../widgets/global/staggered_entrance.dart';
import 'request_detail_screen.dart';
import 'widgets/my_request_card.dart';

/// Les demandes du compte et leur avancement, lues chez OnyxHub (ADR-0073) :
/// ce que l'onglet Demander envoie, on le retrouve ici jusqu'à ce que ce soit
/// disponible.
class MyRequestsScreen extends StatefulWidget {
  const MyRequestsScreen({super.key});

  @override
  State<MyRequestsScreen> createState() => _MyRequestsScreenState();
}

class _MyRequestsScreenState extends State<MyRequestsScreen> {
  late Future<List<MyRequest>> _requests;

  @override
  void initState() {
    super.initState();
    _requests = _load();
  }

  Future<List<MyRequest>> _load() => context.read<ApiClient>().getMyRequests();

  Future<void> _reload() async {
    final next = _load();
    setState(() => _requests = next);
    try {
      await next;
    } catch (_) {
      // L'échec s'affiche par le FutureBuilder, avec « Réessayer ».
    }
  }

  String _errorText(Object? error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['error'] is String) {
        return data['error'] as String;
      }
    }
    return tr('Impossible de charger vos demandes.');
  }

  @override
  Widget build(BuildContext context) {
    final padding = AppLayout.pagePadding(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(tr('Mes demandes'))),
      body: FutureBuilder<List<MyRequest>>(
        future: _requests,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingView();
          }
          if (snapshot.hasError) {
            return ErrorStateView(
                message: _errorText(snapshot.error), onRetry: _reload);
          }
          final requests = snapshot.data ?? const [];
          if (requests.isEmpty) {
            return EmptyStateView(
              icon: AppIcons.request,
              title: tr('Aucune demande'),
              message: tr('Ce que vous demandez depuis l’onglet Demander '
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
                itemBuilder: (context, index) => StaggeredEntrance(
                  index: index,
                  child: MyRequestCard(
                    request: requests[index],
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => RequestDetailScreen(
                            item: requests[index].toRequestItem()))),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
