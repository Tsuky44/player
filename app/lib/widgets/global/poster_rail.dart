import 'package:flutter/material.dart';

import '../../tv/tv_focus_memory.dart';
import '../../utils/responsive.dart';
import 'detail_metadata.dart';
import 'poster_card.dart';

/// Une rangée d'affiches seules au pied d'une fiche (« Titres similaires »,
/// « Recommandations »), la même dans la bibliothèque et les demandes.
class PosterRail extends StatelessWidget {
  final String title;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  const PosterRail({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
  });

  @override
  Widget build(BuildContext context) {
    if (itemCount == 0) return const SizedBox.shrink();
    final pad = AppLayout.pagePadding(context);
    final cardWidth = AppLayout.isCompact(context) ? 112.0 : 142.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding:
              EdgeInsets.fromLTRB(pad, 8, pad, 16 - PosterCard.liftHeadroom),
          child: Text(title, style: detailSectionTitleStyle(context)),
        ),
        // Même mémoire que les rangées de l'accueil — voir [TvFocusMemory].
        TvFocusMemory(
          child: SizedBox(
            height: cardWidth / AppLayout.posterOnlyAspectRatio +
                PosterCard.liftHeadroom,
            child: ListView.separated(
              scrollCacheExtent: AppLayout.imageCacheExtent(context),
              scrollDirection: Axis.horizontal,
              padding:
                  EdgeInsets.fromLTRB(pad, PosterCard.liftHeadroom, pad, 0),
              itemCount: itemCount,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (context, index) =>
                  SizedBox(width: cardWidth, child: itemBuilder(context, index)),
            ),
          ),
        ),
      ],
    );
  }
}
