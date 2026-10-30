import 'package:flutter/material.dart';

import '../../../l10n/tr.dart';
import '../../../models/media_request.dart';
import '../../../models/my_request.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_icons.dart';
import '../../../theme/app_motion.dart';
import '../../../theme/app_type.dart';
import '../../../utils/long_date.dart';
import '../../../utils/responsive.dart';
import '../../../widgets/global/app_network_image.dart';
import 'request_status_motion.dart';

/// Ce que la modération propose sur une carte, ou null pour aucune action.
class MyRequestActions {
  const MyRequestActions({this.onApprove, this.onDecline, this.onDelete});

  final VoidCallback? onApprove;
  final VoidCallback? onDecline;
  final VoidCallback? onDelete;

  bool get isEmpty =>
      onApprove == null && onDecline == null && onDelete == null;
}

/// Une demande du compte, à la manière des cartes « Mes demandes » d'OnyxHub
/// (`RequestCard`) : l'affiche à gauche, le type en surtitre, le titre, le
/// statut en pastille, les saisons demandées et la date de la demande. Avec
/// MediaHub (ADR-0089), la carte dit aussi le statut de chaque saison quand
/// elles diffèrent, la raison d'attente ou le motif de refus, qui a demandé
/// dans la liste de tous les comptes, et les décisions de qui modère.
class MyRequestCard extends StatelessWidget {
  const MyRequestCard({
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

  @override
  Widget build(BuildContext context) {
    final compact = AppLayout.isCompact(context);
    final posterWidth = compact ? 76.0 : 112.0;
    final requestedAt = request.requestedAt;
    final progress = request.progress;
    final isTv = request.mediaType == RequestMediaType.tv;

    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: posterWidth,
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: AppNetworkImage(
                    url: request.posterUrl,
                    width: posterWidth,
                    errorWidget: const ColoredBox(
                      color: AppColors.surfaceElevated,
                      child: Center(
                        child:
                            Icon(AppIcons.poster, color: AppColors.textMuted),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      compact ? 14 : 20, 14, compact ? 14 : 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _TypeLabel(isTv: isTv),
                      const SizedBox(height: 4),
                      Text(
                        request.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize:
                              compact ? AppType.callout : AppType.headline,
                          color: AppColors.textPrimary,
                          height: 1.2,
                        ),
                      ),
                      if (showRequester && request.requester != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          tr('Demandé par {0}', [request.requester!]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: AppType.caption,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: request.hasMixedSeasons
                            ? [
                                // Des saisons à des stades différents : une
                                // pastille par saison dit lesquelles sont là.
                                for (final season in request.seasonStatuses)
                                  MyRequestStatusPill(
                                    status: season.status,
                                    prefix: tr('S{0}', ['${season.number}']),
                                    showTrack: progress == null,
                                  ),
                              ]
                            : [
                                MyRequestStatusPill(
                                  status: request.status,
                                  // Une progression chiffrée remplace la
                                  // barre indéterminée de la pastille.
                                  showTrack: progress == null,
                                ),
                                if (isTv && request.seasons.isNotEmpty)
                                  _SeasonsChip(seasons: request.seasons),
                              ],
                      ),
                      if (progress != null) ...[
                        const SizedBox(height: 10),
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
                        const SizedBox(height: 10),
                        Text(
                          detail,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppType.caption,
                            color: request.status == MyRequestStatus.declined
                                ? AppColors.error
                                : AppColors.textMuted,
                          ),
                        ),
                      ],
                      const Spacer(),
                      if (requestedAt != null) ...[
                        const SizedBox(height: 10),
                        Divider(
                          height: 1,
                          color: Colors.white.withValues(alpha: 0.06),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          tr('Ajouté le {0}',
                              [formatLongDate(requestedAt.toLocal())]),
                          style: const TextStyle(
                            fontSize: AppType.micro,
                            color: AppColors.textMuted,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                      if (!actions.isEmpty)
                        _ModerationBar(actions: actions, busy: busy),
                    ],
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(right: 10),
                child: Icon(AppIcons.chevronRight, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// « FILM » / « SÉRIE » en surtitre, la seule touche d'accent de la carte.
class _TypeLabel extends StatelessWidget {
  const _TypeLabel({required this.isTv});

  final bool isTv;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.accentMuted.withValues(alpha: 0.85);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(isTv ? AppIcons.series : AppIcons.movie, size: 12, color: color),
        const SizedBox(width: 5),
        Text(
          (isTv ? tr('Série') : tr('Film')).toUpperCase(),
          style: TextStyle(
            fontSize: AppType.micro,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _SeasonsChip extends StatelessWidget {
  const _SeasonsChip({required this.seasons});

  final List<int> seasons;

  @override
  Widget build(BuildContext context) {
    final label = seasons.length == 1
        ? tr('Saison {0}', ['${seasons.first}'])
        : tr('Saisons {0}', [seasons.join(', ')]);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.2)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: AppType.caption,
          fontWeight: FontWeight.w700,
          color: AppColors.accentMuted,
        ),
      ),
    );
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
              style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary),
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

/// La pastille de statut d'une demande, au code d'OnyxHub : un fond sourd,
/// l'icône seule en couleur, un faisceau qui traverse une fois « Disponible »
/// et une mince barre qui court sous « En cours ». [prefix] la fait précéder
/// de sa saison quand les saisons d'une série diffèrent.
class MyRequestStatusPill extends StatelessWidget {
  const MyRequestStatusPill({
    super.key,
    required this.status,
    this.prefix,
    this.showTrack = true,
  });

  final MyRequestStatus status;
  final String? prefix;

  /// La barre indéterminée sous « En cours ».
  final bool showTrack;

  @override
  Widget build(BuildContext context) {
    final (label, icon, tint) = switch (status) {
      MyRequestStatus.available => (
          tr('Disponible'),
          AppIcons.watched,
          AppColors.success
        ),
      MyRequestStatus.partial => (
          tr('Partiellement disponible'),
          AppIcons.pending,
          AppColors.warning
        ),
      MyRequestStatus.processing => (
          tr('En cours'),
          AppIcons.download,
          AppColors.warning
        ),
      MyRequestStatus.approved => (
          tr('Approuvée'),
          AppIcons.check,
          AppColors.textSecondary
        ),
      MyRequestStatus.pending => (
          tr('En attente'),
          AppIcons.schedule,
          AppColors.warning
        ),
      MyRequestStatus.declined => (
          tr('Refusée'),
          AppIcons.close,
          AppColors.error
        ),
    };
    final available = status == MyRequestStatus.available;
    // La barre court sans fin : en mode léger elle disparaît plutôt que de
    // garder le moteur en train de dessiner (ADR-0086).
    final track = showTrack &&
        status == MyRequestStatus.processing &&
        !AppMotion.reduced(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: available ? 0.06 : 0.04),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: Colors.white.withValues(alpha: available ? 0.15 : 0.1),
          ),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: tint),
                const SizedBox(width: 6),
                Text(
                  (prefix == null ? label : '$prefix · $label').toUpperCase(),
                  style: const TextStyle(
                    fontSize: AppType.micro,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
            if (available) const Positioned.fill(child: StatusBeam()),
            if (track)
              const Positioned(
                left: 0,
                right: 0,
                bottom: -4,
                child: StatusTrack(),
              ),
          ],
        ),
      ),
    );
  }
}
