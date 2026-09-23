import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_focus_memory.dart';
import '../../utils/poster_url.dart';
import '../../utils/responsive.dart';
import 'continue_watching_card.dart';
import 'media_card.dart';
import 'poster_card.dart';
import 'poster_launch_route.dart';

class MediaRow extends StatelessWidget {
  final String title;
  final List<dynamic> items;
  final VoidCallback? onSeeAll;
  final void Function(dynamic item) onItemTap;

  /// Lecture depuis « Reprendre ». Sans elle, la carte retombe sur [onItemTap].
  final void Function(HomeMediaItem item, LaunchOrigin? origin)?
      onContinueWatchingPlay;
  final void Function(HomeMediaItem item, LaunchOrigin? origin)?
      onContinueWatchingTitleTap;
  final Future<void> Function(HomeMediaItem item)?
      onContinueWatchingMarkWatched;
  final Future<void> Function(HomeMediaItem item)? onContinueWatchingRemove;
  final bool isContinueWatching;

  /// Hands the remote's starting position to this row's first card. Set by the
  /// screen on its topmost row, so a television opens on the content rather
  /// than on whichever header control the traversal policy sorts first.
  final bool autofocusFirstItem;

  const MediaRow({
    super.key,
    required this.title,
    required this.items,
    required this.onItemTap,
    this.onContinueWatchingPlay,
    this.onContinueWatchingTitleTap,
    this.onContinueWatchingMarkWatched,
    this.onContinueWatchingRemove,
    this.onSeeAll,
    this.isContinueWatching = false,
    this.autofocusFirstItem = false,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    final horizontalPadding = AppLayout.pagePadding(context);
    final cardWidth = AppLayout.mediaRowCardWidth(context);
    final compact = AppLayout.isCompact(context);
    final rowHeight = isContinueWatching
        ? ContinueWatchingCard.rowHeight + PosterCard.liftHeadroom
        : mediaCardHeight(cardWidth, compact: true) +
            4 +
            PosterCard.liftHeadroom;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: compact ? 17 : 20,
                        letterSpacing: -0.3,
                      ),
                ),
              ),
              if (onSeeAll != null)
                TextButton(
                  onPressed: onSeeAll,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Tout voir',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                      SizedBox(width: 2),
                      Icon(Icons.chevron_right_rounded,
                          size: 20, color: AppColors.textSecondary),
                    ],
                  ),
                ),
            ],
          ),
        ),
        // La marge réservée au zoom des affiches ([PosterCard.liftHeadroom])
        // est reprise ici, pour que l'écart visible sous le titre ne change pas.
        const SizedBox(height: 14 - PosterCard.liftHeadroom),
        // Revenir sur cette rangée ramène à la carte où l'on était — voir
        // [TvFocusMemory].
        TvFocusMemory(
          child: SizedBox(
            height: rowHeight,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.only(
                left: horizontalPadding,
                right: horizontalPadding,
                top: PosterCard.liftHeadroom,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return Padding(
                  padding:
                      EdgeInsets.only(right: index < items.length - 1 ? 12 : 0),
                  child: isContinueWatching
                      ? ContinueWatchingCard(
                          item: item as HomeMediaItem,
                          autofocus: autofocusFirstItem && index == 0,
                          onTap: (origin) => onContinueWatchingPlay != null
                              ? onContinueWatchingPlay!(item, origin)
                              : onItemTap(item),
                          onTitleTap: onContinueWatchingTitleTap != null
                              ? (origin) =>
                                  onContinueWatchingTitleTap!(item, origin)
                              : null,
                          onMarkAsWatched: onContinueWatchingMarkWatched,
                          onRemoveFromRow: onContinueWatchingRemove,
                        )
                      : SizedBox(
                          width: cardWidth,
                          child: MediaCard(
                            media: item as Media,
                            compact: true,
                            autofocus: autofocusFirstItem && index == 0,
                            onTap: () => onItemTap(item),
                          ),
                        ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
