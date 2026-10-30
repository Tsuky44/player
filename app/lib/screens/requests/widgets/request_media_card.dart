import 'package:flutter/material.dart';
import '../../../models/media_request.dart';
import '../../../utils/poster_url.dart';
import '../../../widgets/global/poster_card.dart';
import '../../../widgets/global/poster_card_details.dart';
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
      hoverDetails: PosterCardDetails(
        title: item.title,
        typeLabel: item.mediaType == RequestMediaType.movie
            ? tr('Film')
            : tr('Série'),
        facts: [
          if (item.year != null) item.year!,
          if (item.rating > 0) '★ ${item.rating.toStringAsFixed(1)}',
        ].join('  ·  '),
        overview: item.overview,
      ),
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
