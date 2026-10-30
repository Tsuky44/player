import 'package:flutter/material.dart';
import '../../../models/media_request.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/poster_url.dart';
import '../../../widgets/global/poster_card.dart';
import '../../../theme/app_type.dart';
import '../../../l10n/tr.dart';
import '../../../widgets/global/poster_flight.dart';
import '../request_detail_launch.dart';
import 'request_status_dot.dart';

/// Une affiche du catalogue Demander, comme les cartes d'OnyxHub
/// (`MediaCard`) : l'affiche seule, la pastille de statut en haut à droite, et
/// le titre, le type et le résumé qui montent du bas quand elle est pointée.
///
/// Sans [onTap], toucher la carte ouvre la fiche par l'envol de l'affiche
/// (`openRequestDetail`), et s'attarder dessus préchauffe les images que
/// l'envol dessinera.
class RequestMediaCard extends StatelessWidget {
  final RequestMediaItem item;
  final VoidCallback? onTap;

  const RequestMediaCard({
    super.key,
    required this.item,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PosterCard(
      posterUrl: cardPosterUrl(item.posterUrl),
      title: item.title,
      showMeta: false,
      onTap: onTap ?? () => openRequestDetail(context, item),
      onPrefetch: onTap != null
          ? null
          : () => PosterFlight.warm(
                context,
                posterUrl: cardPosterUrl(item.posterUrl),
                posterWidth: context.size?.width ?? 0,
                backdropUrl: detailBackdropUrl(item.backdropUrl),
              ),
      hoverDetails: _RequestCardDetails(item: item),
      overlays: [
        if (item.status != RequestMediaStatus.unknown)
          Positioned(
            top: PosterCard.overlayInset,
            right: PosterCard.overlayInset,
            child: RequestStatusDot(
              status: item.status,
              awaitingRelease: item.isAwaitingRelease(),
            ),
          ),
      ],
    );
  }
}

/// Le cartouche d'une affiche pointée : titre, pastille de type avec l'année
/// et la note, puis le début du résumé.
class _RequestCardDetails extends StatelessWidget {
  final RequestMediaItem item;

  const _RequestCardDetails({required this.item});

  @override
  Widget build(BuildContext context) {
    final facts = [
      if (item.year != null) item.year!,
      if (item.rating > 0) '★ ${item.rating.toStringAsFixed(1)}',
    ].join('  ·  ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HoverLine(
          rank: 0,
          child: Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: AppType.body,
              height: 1.15,
            ),
          ),
        ),
        const SizedBox(height: 6),
        HoverLine(
          rank: 1,
          child: Row(
            children: [
              _TypePill(type: item.mediaType),
              if (facts.isNotEmpty) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    facts,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: AppType.micro,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (item.overview.isNotEmpty) ...[
          const SizedBox(height: 6),
          HoverLine(
            rank: 2,
            child: Text(
              item.overview,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppType.caption,
                height: 1.35,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Pastille de verre « Film » / « Série ». Fond uni plutôt que flouté : elle
/// apparaît sur chaque carte pointée, et un flou par carte se paierait à
/// chaque image d'un déplacement du focus.
class _TypePill extends StatelessWidget {
  final RequestMediaType type;

  const _TypePill({required this.type});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Text(
        (type == RequestMediaType.movie ? tr('Film') : tr('Série'))
            .toUpperCase(),
        style: const TextStyle(
          fontSize: AppType.micro,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}
