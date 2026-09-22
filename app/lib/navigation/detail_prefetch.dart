import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/library_provider.dart';
import '../services/api_client.dart';
import '../services/media_details_cache.dart';
import '../services/media_tracks_cache.dart';
import '../utils/responsive.dart';
import '../widgets/global/media_detail_widgets.dart';

/// Head start for a movie or show page, taken while the user is still pointing
/// at its card (mouse hover, remote focus) or pressing it.
///
/// Everything the page draws first is fetched into the caches it reads on its
/// first frame: the details payload ([MediaDetailsCache]), the header and cast
/// artwork decoded at their exact slot sizes, the track list of a film
/// ([MediaTracksCache]) and the seasons + resume point of a show. By the time
/// the open transition ends the page is complete rather than filling in.
///
/// Calls are cheap to repeat: every cache dedupes in-flight work, and a title
/// warmed less than [_cooldown] ago is skipped outright.
class DetailPrefetch {
  DetailPrefetch._();

  static const Duration _cooldown = Duration(minutes: 5);
  static final Map<int, DateTime> _warmedAt = {};

  static void warm(BuildContext context, Media media) {
    final id = media.id;
    if (id <= 0) return;
    if (media.type != MediaType.movie && media.type != MediaType.show) return;

    final last = _warmedAt[id];
    final now = DateTime.now();
    if (last != null && now.difference(last) < _cooldown) return;
    _warmedAt[id] = now;

    // Everything context-bound is read now: the card may be gone by the time
    // the network answers.
    final api = Provider.of<ApiClient>(context, listen: false);
    final library = Provider.of<LibraryProvider>(context, listen: false);
    final screenSize = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final compact = AppLayout.isCompact(context);

    unawaited(() async {
      try {
        final details = await MediaDetailsCache.load(api, id);
        await DetailBackdropHeader.precacheArtwork(
          details: details,
          fallback: media,
          baseUrl: api.baseUrl,
          screenSize: screenSize,
          devicePixelRatio: dpr,
          compact: compact,
        );
      } catch (_) {
        // A failed warm-up must not block the next one.
        _warmedAt.remove(id);
      }
    }());

    if (media.type == MediaType.movie) {
      final playbackId =
          media.versions.isNotEmpty ? media.versions.first.item.media.id : id;
      unawaited(
        MediaTracksCache.load(api, playbackId).then<void>((_) {}, onError: (_) {}),
      );
    } else {
      unawaited(library.prefetchShow(id));
    }
  }
}
