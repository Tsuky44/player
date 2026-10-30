import 'package:flutter/material.dart';

import '../../models/media_request.dart';
import '../../theme/lite_mode.dart';
import '../../utils/poster_url.dart';
import '../../widgets/global/poster_card.dart';
import '../../widgets/global/poster_flight.dart';
import 'request_detail_screen.dart';
import 'widgets/request_detail_hero.dart';

/// Ouvre la fiche d'une demande depuis sa carte : l'affiche s'envole vers le
/// fond de la fiche (voir [PosterFlightRoute], ADR-0094).
///
/// Une route ordinaire dans tous les autres cas : mouvement réduit demandé,
/// titre sans fond connu, ou carte qui n'est plus posée à l'écran.
Future<void> openRequestDetail(
  BuildContext cardContext,
  RequestMediaItem item,
) {
  final navigator = Navigator.of(cardContext);
  final route = _flightRoute(cardContext, navigator, item);
  return navigator.push(
    route ??
        MaterialPageRoute<void>(
            builder: (_) => RequestDetailScreen(item: item)),
  );
}

Route<void>? _flightRoute(
  BuildContext cardContext,
  NavigatorState navigator,
  RequestMediaItem item,
) {
  if (MediaQuery.disableAnimationsOf(cardContext)) return null;
  final backdrop = detailBackdropUrl(item.backdropUrl);
  if (backdrop == null) return null;

  final card = cardContext.findRenderObject();
  final stage = navigator.context.findRenderObject();
  if (card is! RenderBox || stage is! RenderBox) return null;
  if (!card.attached || !stage.attached || !card.hasSize) return null;
  final from = card.localToGlobal(Offset.zero, ancestor: stage) & card.size;
  // Une carte à moitié sortie de l'écran s'envolerait de nulle part.
  if (!(Offset.zero & stage.size).overlaps(from)) return null;

  return PosterFlightRoute<void>(
    from: from,
    radius: PosterCard.radius,
    posterUrl: cardPosterUrl(item.posterUrl),
    backdropUrl: backdrop,
    backdropHeight: RequestDetailBackdrop.heightFor(cardContext),
    lite: LiteScope.of(cardContext),
    builder: (_) => RequestDetailScreen(item: item),
  );
}
