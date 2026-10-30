import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/tr.dart';
import '../../models/models.dart';
import '../../navigation/detail_flight.dart';
import '../../navigation/detail_prefetch.dart';
import '../../services/api_client.dart';
import '../../utils/format.dart';
import '../../utils/poster_url.dart';
import 'poster_card.dart';
import 'poster_card_details.dart';
import 'progress_pill.dart';
import 'watch_badge.dart';
import '../../theme/app_icons.dart';

/// Une affiche de la bibliothèque, au dessin de celles de Demander : l'affiche
/// seule, le cartouche quand elle est pointée. Le vu et la progression restent
/// posés dessus.
///
/// Sans [onTap], toucher la carte ouvre la fiche par l'envol de l'affiche
/// ([openMediaDetail]).
class MediaCard extends StatelessWidget {
  final Media media;
  final double? progress;

  /// La progression d'un film, que sa fiche affiche dès l'ouverture.
  final HomeMediaItem? item;

  /// Film déjà vu — la pastille verte. Ignoré pour les séries, qui déduisent la
  /// leur du décompte d'épisodes porté par [media].
  final bool watched;
  final VoidCallback? onTap;
  final bool compact;

  /// See [PosterCard.autofocus].
  final bool autofocus;

  const MediaCard({
    super.key,
    required this.media,
    this.progress,
    this.item,
    this.watched = false,
    this.onTap,
    this.compact = false,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final apiClient = Provider.of<ApiClient>(context, listen: false);
    final url = cardPosterUrl(media.posterUrl, serverBaseUrl: apiClient.baseUrl);
    final year = extractYear(media.releaseDate);
    final isShow = media.type == MediaType.show ||
        media.type == MediaType.season ||
        media.type == MediaType.episode;
    final inProgress = progress != null && progress! > 0 && progress! < 0.99;
    final badge = WatchBadge.forMedia(media, watched: watched);

    return PosterCard(
      posterUrl: url,
      title: media.title,
      showMeta: false,
      onTap: onTap ?? () => openMediaDetail(context, media, item: item),
      onPrefetch: () => DetailPrefetch.warm(context, media),
      compact: compact,
      autofocus: autofocus,
      placeholderIcon: isShow ? AppIcons.series : AppIcons.movie,
      hoverDetails: PosterCardDetails(
        title: media.title,
        typeLabel: isShow ? tr('Série') : tr('Film'),
        facts: year,
        overview: media.overview,
      ),
      overlays: [
        if (badge != null)
          Positioned(
            top: PosterCard.overlayInset,
            right: PosterCard.overlayInset,
            child: badge,
          ),
      ],
      footerOverlay: inProgress ? ProgressPill(value: progress!) : null,
    );
  }
}
