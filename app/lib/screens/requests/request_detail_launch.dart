import 'package:flutter/material.dart';

import '../../models/media_request.dart';
import '../../navigation/detail_flight.dart';
import '../../utils/poster_url.dart';
import 'request_detail_screen.dart';

/// Ouvre la fiche d'une demande depuis sa carte, par l'envol commun à toutes
/// les fiches ([pushDetailFlight]).
Future<void> openRequestDetail(
  BuildContext cardContext,
  RequestMediaItem item,
) {
  return pushDetailFlight(
    cardContext,
    posterUrl: cardPosterUrl(item.posterUrl),
    backdropUrl: detailBackdropUrl(item.backdropUrl),
    builder: (_) => RequestDetailScreen(item: item),
  );
}
