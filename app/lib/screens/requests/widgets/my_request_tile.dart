import 'package:flutter/material.dart';

import '../../../l10n/tr.dart';
import '../../../models/my_request.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_icons.dart';
import '../../../theme/app_type.dart';
import '../../../widgets/global/app_network_image.dart';

/// Ce que la modération propose sur une carte, ou null pour aucune action.
class MyRequestActions {
  const MyRequestActions({this.onApprove, this.onDecline, this.onDelete});

  final VoidCallback? onApprove;
  final VoidCallback? onDecline;
  final VoidCallback? onDelete;

  bool get isEmpty => onApprove == null && onDecline == null && onDelete == null;
}

/// Une demande et son avancement : statut, saisons, raison d'attente ou motif
/// de refus (ADR-0087), et, pour qui modère, les décisions.
class MyRequestTile extends StatelessWidget {
  const MyRequestTile({
    super.key,
    required this.request,
    required this.onTap,
    this.showRequester = false,
    this.actions = const MyRequestActions(),
    this.busy = false,
  });

  final MyRequest request;
  final VoidCallback onTap;

  /// Dans la liste de tous les comptes : qui a demandé.
  final bool showRequester;
  final MyRequestActions actions;

  /// Une décision part : les boutons attendent la réponse.
  final bool busy;

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
    final subtitle = showRequester && request.requester != null
        ? tr('{0} · demandé par {1}', [_seasons, request.requester!])
        : _seasons;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
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
                        Text(subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: AppType.caption,
                                color: AppColors.textSecondary)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: request.hasMixedSeasons
                              ? [
                                  for (final season in request.seasonStatuses)
                                    MyRequestStatusPill(
                                      status: season.status,
                                      prefix: tr('S{0}', ['${season.number}']),
                                    ),
                                ]
                              : [MyRequestStatusPill(status: request.status)],
                        ),
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
                        if (_detail case final detail?) ...[
                          const SizedBox(height: 8),
                          Text(detail,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: AppType.caption,
                                  color: request.status ==
                                          MyRequestStatus.declined
                                      ? AppColors.error
                                      : AppColors.textMuted)),
                        ],
                      ],
                    ),
                  ),
                  const Icon(AppIcons.chevronRight, color: AppColors.textMuted),
                ],
              ),
              if (!actions.isEmpty) _ModerationBar(actions: actions, busy: busy),
            ],
          ),
        ),
      ),
    );
  }

  /// La ligne sous le statut : le motif d'un refus, ou pourquoi rien ne se
  /// télécharge encore.
  String? get _detail {
    if (request.status == MyRequestStatus.declined) {
      final note = request.note;
      return note == null ? tr('Refusée.') : tr('Refusée : {0}', [note]);
    }
    if (request.status == MyRequestStatus.available) return null;
    return request.waitingMessage;
  }
}

class _ModerationBar extends StatelessWidget {
  const _ModerationBar({required this.actions, required this.busy});

  final MyRequestActions actions;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    VoidCallback? enabled(VoidCallback? action) => busy ? null : action;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 4,
        children: [
          if (actions.onDelete != null)
            TextButton.icon(
              onPressed: enabled(actions.onDelete),
              icon: const Icon(AppIcons.delete, size: 18),
              label: Text(tr('Supprimer')),
              style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
            ),
          if (actions.onDecline != null)
            TextButton.icon(
              onPressed: enabled(actions.onDecline),
              icon: const Icon(AppIcons.close, size: 18),
              label: Text(tr('Refuser')),
              style: TextButton.styleFrom(foregroundColor: AppColors.error),
            ),
          if (actions.onApprove != null)
            FilledButton.icon(
              onPressed: enabled(actions.onApprove),
              icon: const Icon(AppIcons.check, size: 18),
              label: Text(tr('Approuver')),
            ),
        ],
      ),
    );
  }
}

/// La pastille d'un statut de demande, éventuellement précédée de sa saison.
class MyRequestStatusPill extends StatelessWidget {
  const MyRequestStatusPill({super.key, required this.status, this.prefix});

  final MyRequestStatus status;
  final String? prefix;

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
      MyRequestStatus.declined => (tr('Refusée'), AppColors.error),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(prefix == null ? label : '$prefix · $label',
          style: TextStyle(
              color: color,
              fontSize: AppType.caption,
              fontWeight: FontWeight.w600)),
    );
  }
}
