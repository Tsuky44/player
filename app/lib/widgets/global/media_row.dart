import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../theme/app_colors.dart';
import '../../utils/poster_url.dart';
import 'continue_watching_card.dart';
import 'media_card.dart';

class MediaRow extends StatelessWidget {
  final String title;
  final List<dynamic> items;
  final VoidCallback? onSeeAll;
  final void Function(dynamic item) onItemTap;
  final void Function(HomeMediaItem item)? onContinueWatchingTitleTap;
  final Future<void> Function(HomeMediaItem item)? onContinueWatchingMarkWatched;
  final Future<void> Function(HomeMediaItem item)? onContinueWatchingRemove;
  final bool isContinueWatching;

  const MediaRow({
    super.key,
    required this.title,
    required this.items,
    required this.onItemTap,
    this.onContinueWatchingTitleTap,
    this.onContinueWatchingMarkWatched,
    this.onContinueWatchingRemove,
    this.onSeeAll,
    this.isContinueWatching = false,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    final horizontalPadding = MediaQuery.sizeOf(context).width >= 900 ? 48.0 : 16.0;
    const cardWidth = 150.0;
    final rowHeight = isContinueWatching
        ? ContinueWatchingCard.rowHeight
        : mediaCardHeight(cardWidth, compact: true) + 4;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Row(
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontSize: 20,
                    ),
              ),
              if (onSeeAll != null) ...[
                const Spacer(),
                TextButton(
                  onPressed: onSeeAll,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Tout voir',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                      SizedBox(width: 4),
                      Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.textSecondary),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: rowHeight,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return Padding(
                padding: EdgeInsets.only(right: index < items.length - 1 ? 12 : 0),
                child: isContinueWatching
                    ? ContinueWatchingCard(
                        item: item as HomeMediaItem,
                        onTap: () => onItemTap(item),
                        onTitleTap: onContinueWatchingTitleTap != null
                            ? () => onContinueWatchingTitleTap!(item as HomeMediaItem)
                            : null,
                        onMarkAsWatched: onContinueWatchingMarkWatched,
                        onRemoveFromRow: onContinueWatchingRemove,
                      )
                    : SizedBox(
                        width: cardWidth,
                        child: MediaCard(
                          media: item as Media,
                          compact: true,
                          onTap: () => onItemTap(item),
                        ),
                      ),
              );
            },
          ),
        ),
      ],
    );
  }
}
