import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/library_provider.dart';
import '../screens/library/movie_detail_screen.dart';
import '../screens/library/show_detail_screen.dart';
import '../services/api_client.dart';
import '../services/media_details_cache.dart';
import '../theme/lite_mode.dart';
import '../utils/poster_url.dart';
import '../widgets/global/detail_backdrop_header.dart';
import '../widgets/global/detail_hero.dart';
import '../widgets/global/poster_card.dart';
import '../widgets/global/poster_flight.dart';
import '../widgets/global/poster_launch_route.dart';

/// Ouvre une fiche, quelle qu'elle soit, depuis sa carte : l'affiche s'envole
/// vers le fond de la fiche (voir [PosterFlightRoute], ADR-0094 et ADR-0099).
///
/// Une route ordinaire dans tous les autres cas : mouvement réduit demandé,
/// titre sans fond connu, ou carte qui n'est plus posée à l'écran.
///
/// [from] est le cadre de la carte à l'écran quand l'appelant l'a déjà mesuré
/// ; sans lui, c'est [cardContext] qui se mesure, s'il [measureCard].
Future<void> pushDetailFlight(
  BuildContext cardContext, {
  required String? posterUrl,
  required String? backdropUrl,
  required WidgetBuilder builder,
  Rect? from,
  bool measureCard = true,
}) {
  final navigator = Navigator.of(cardContext);
  final route = _flightRoute(cardContext, navigator,
      posterUrl: posterUrl,
      backdropUrl: backdropUrl,
      builder: builder,
      from: from,
      measureCard: measureCard);
  return navigator.push(route ?? MaterialPageRoute<void>(builder: builder));
}

Route<void>? _flightRoute(
  BuildContext cardContext,
  NavigatorState navigator, {
  required String? posterUrl,
  required String? backdropUrl,
  required WidgetBuilder builder,
  required Rect? from,
  required bool measureCard,
}) {
  if (MediaQuery.disableAnimationsOf(cardContext)) return null;
  if (backdropUrl == null) return null;

  final stage = navigator.context.findRenderObject();
  if (stage is! RenderBox || !stage.attached) return null;
  final Rect origin;
  if (from != null) {
    // Le navigateur imbriqué ne couvre pas forcément tout l'écran (barre
    // latérale du shell) : l'origine est ramenée dans son repère à lui.
    origin = stage.globalToLocal(from.topLeft) & from.size;
  } else {
    if (!measureCard) return null;
    final card = cardContext.findRenderObject();
    if (card is! RenderBox || !card.attached || !card.hasSize) return null;
    origin = card.localToGlobal(Offset.zero, ancestor: stage) & card.size;
  }
  // Une carte à moitié sortie de l'écran s'envolerait de nulle part.
  if (!(Offset.zero & stage.size).overlaps(origin)) return null;

  return PosterFlightRoute<void>(
    from: origin,
    radius: PosterCard.radius,
    posterUrl: posterUrl,
    backdropUrl: backdropUrl,
    backdropHeight: DetailBackdrop.heightFor(cardContext),
    lite: LiteScope.of(cardContext),
    builder: builder,
  );
}

/// Combien de temps un toucher attend le fond d'un titre jamais survolé.
///
/// Une carte de la bibliothèque ne connaît pas son fond : il est dans la fiche,
/// que l'appui a déjà demandée (`DetailPrefetch`). Sur un téléphone, il n'y a
/// pas de survol pour la préparer : sans cette attente, le premier toucher sur
/// chaque titre aurait une route ordinaire. Au-delà, la route ordinaire vaut
/// mieux qu'un appui qui semble ignoré.
const Duration _backdropPatience = Duration(milliseconds: 300);

bool _opening = false;

/// Ouvre la fiche d'un film ou d'une série de la bibliothèque depuis sa carte.
///
/// [item] porte la progression d'un film. [origin], le cadre d'une carte qui
/// l'a mesuré elle-même (« Reprendre ») ; [measureCard] faux si [cardContext]
/// n'est pas une carte et qu'il ne faut pas le mesurer.
Future<void> openMediaDetail(
  BuildContext cardContext,
  Media media, {
  HomeMediaItem? item,
  LaunchOrigin? origin,
  bool measureCard = true,
}) async {
  if (_opening) return;
  final Media target;
  if (media.type == MediaType.movie) {
    target = media;
  } else if (media.type == MediaType.show) {
    target = Provider.of<LibraryProvider>(cardContext, listen: false)
        .resolveCanonicalShow(media);
  } else {
    return;
  }
  final api = Provider.of<ApiClient>(cardContext, listen: false);

  _opening = true;
  final MediaDetails? details;
  try {
    details = await _detailsForFlight(cardContext, api, target.id);
  } finally {
    _opening = false;
  }
  if (!cardContext.mounted) return;

  return pushDetailFlight(
    cardContext,
    posterUrl: origin?.imageUrl ??
        cardPosterUrl(target.posterUrl, serverBaseUrl: api.baseUrl),
    backdropUrl: details == null
        ? null
        : detailBackdropUrl(
            DetailBackdropHeader.backdropSource(details, target),
            serverBaseUrl: api.baseUrl,
          ),
    from: origin?.rect,
    measureCard: measureCard,
    builder: (_) => target.type == MediaType.show
        ? ShowDetailScreen(show: target)
        : MovieDetailScreen(movie: target, movieItem: item),
  );
}

Future<MediaDetails?> _detailsForFlight(
  BuildContext context,
  ApiClient api,
  int id,
) async {
  final cached = MediaDetailsCache.peek(id);
  if (cached != null) return cached;
  // Pas d'envol à préparer : rien ne justifie de retenir l'appui.
  if (MediaQuery.disableAnimationsOf(context)) return null;
  try {
    return await MediaDetailsCache.load(api, id).timeout(_backdropPatience);
  } catch (_) {
    // Lente ou en échec, la fiche s'ouvre par une route ordinaire et se charge
    // elle-même : c'est elle qui dira ce qui ne va pas.
    return null;
  }
}
