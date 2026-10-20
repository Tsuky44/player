import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/tr.dart';
import '../../models/my_request.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/app_network_image.dart';
import '../../widgets/global/empty_state.dart';
import 'request_detail_screen.dart';

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
      if (data is Map && data['error'] is String)
        return data['error'] as String;
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
            child: ListView.separated(
              padding: EdgeInsets.fromLTRB(padding, 12, padding, 32),
              itemCount: requests.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) => _MyRequestTile(
                request: requests[index],
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => RequestDetailScreen(
                        item: requests[index].toRequestItem()))),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MyRequestTile extends StatelessWidget {
  const _MyRequestTile({required this.request, required this.onTap});

  final MyRequest request;
  final VoidCallback onTap;

  String get _seasons {
    if (request.seasons.isEmpty) return tr('Film');
    if (request.seasons.length == 1) {
      return tr('Saison {0}', ['${request.seasons.first}']);
    }
    return tr('Saisons {0}', [request.seasons.join(', ')]);
  }

  @override
  Widget build(BuildContext context) {
    final progress = request.progress;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AppNetworkImage(
                    url: request.posterUrl,
                    width: 56,
                    height: 84,
                    fit: BoxFit.cover),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: AppType.body,
                          color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    Text(_seasons,
                        style: const TextStyle(
                            fontSize: AppType.caption,
                            color: AppColors.textSecondary)),
                    const SizedBox(height: 8),
                    _StatusPill(status: request.status),
                    if (progress != null) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: (progress / 100).clamp(0, 1),
                          minHeight: 4,
                          color: AppColors.progress,
                          backgroundColor: AppColors.surfaceHover,
                          semanticsLabel: tr('Téléchargement'),
                          semanticsValue: '${progress.round()} %',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(AppIcons.chevronRight, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final MyRequestStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      MyRequestStatus.pending => (tr('En attente'), AppColors.warning),
      MyRequestStatus.approved => (tr('Approuvée'), AppColors.accentMuted),
      MyRequestStatus.processing => (tr('En cours'), AppColors.accentMuted),
      MyRequestStatus.partial => (
          tr('Partiellement disponible'),
          AppColors.warning
        ),
      MyRequestStatus.available => (tr('Disponible'), AppColors.success),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(label,
          style: TextStyle(
              color: color,
              fontSize: AppType.caption,
              fontWeight: FontWeight.w600)),
    );
  }
}
