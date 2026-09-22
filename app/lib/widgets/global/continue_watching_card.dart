import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_focus.dart';
import '../../utils/format.dart';
import '../../utils/poster_url.dart';
import 'media_poster.dart';
import 'poster_card.dart';
import 'poster_launch_route.dart';
import 'progress_pill.dart';

class ContinueWatchingCard extends StatefulWidget {
  /// TMDB posters are 2:3 — match that ratio so faces/titles aren't cropped.
  static const cardWidth = 176.0;
  static const posterHeight = cardWidth * 1.5;
  static const rowHeight = posterHeight + 6 + 40; // poster + gap + 2 text lines

  final HomeMediaItem item;

  /// Reçoit l'affiche touchée, pour que l'écran suivant s'ouvre en la faisant
  /// grandir — voir [pushPosterLaunch].
  final void Function(LaunchOrigin? origin) onTap;
  final void Function(LaunchOrigin? origin)? onTitleTap;
  final Future<void> Function(HomeMediaItem item)? onMarkAsWatched;
  final Future<void> Function(HomeMediaItem item)? onRemoveFromRow;

  /// Takes the remote's focus on build. Set on the first card of the row, so a
  /// television opens on "Reprendre" — the one thing anyone wants from a couch.
  final bool autofocus;

  const ContinueWatchingCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onTitleTap,
    this.onMarkAsWatched,
    this.onRemoveFromRow,
    this.autofocus = false,
  });

  @override
  State<ContinueWatchingCard> createState() => _ContinueWatchingCardState();
}

class _ContinueWatchingCardState extends State<ContinueWatchingCard> {
  bool _hovered = false;
  bool _focused = false;
  final _posterKey = GlobalKey();

  /// Pointer hover and D-pad focus mean the same thing here.
  bool get _active => _hovered || _focused;

  LaunchOrigin? _origin() => LaunchOrigin.fromKey(
        _posterKey,
        imageUrl: cardPosterUrl(
          widget.item.displayPosterUrl,
          serverBaseUrl: Provider.of<ApiClient>(context, listen: false).baseUrl,
        ),
      );

  void _play() => widget.onTap(_origin());

  /// Where a remote's context menu opens, since there is no cursor to anchor it
  /// to: the middle of the screen.
  void _showContextMenuCentred() {
    final size = MediaQuery.sizeOf(context);
    _showContextMenu(Offset(size.width / 2, size.height / 2));
  }

  Future<void> _showContextMenu(Offset globalPosition) async {
    if (widget.onMarkAsWatched == null && widget.onRemoveFromRow == null) {
      return;
    }

    final action = await showMenu<String>(
      context: context,
      // The position is in screen coordinates: measured against the root
      // overlay, not the shell's navigator.
      useRootNavigator: true,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & MediaQuery.sizeOf(context),
      ),
      color: AppColors.surfaceElevated,
      items: [
        if (widget.onMarkAsWatched != null)
          const PopupMenuItem(
            value: 'watched',
            child: Text('Marquer comme vu'),
          ),
        if (widget.onRemoveFromRow != null)
          const PopupMenuItem(
            value: 'hide',
            child: Text('Supprimer de Reprendre'),
          ),
      ],
    );

    if (!mounted || action == null) return;

    try {
      switch (action) {
        case 'watched':
          await widget.onMarkAsWatched?.call(widget.item);
        case 'hide':
          await widget.onRemoveFromRow?.call(widget.item);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Action impossible : $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    const width = ContinueWatchingCard.cardWidth;
    const height = ContinueWatchingCard.posterHeight;
    final progress = widget.item.percentWatched;
    final detail = _detailLine();

    return TvFocusable(
      onSelect: _play,
      // The remote's menu button reaches the same two actions the mouse gets
      // from a right-click and the phone from a long press.
      onContextMenu: _showContextMenuCentred,
      autofocus: widget.autofocus,
      borderRadius: BorderRadius.circular(12),
      showRing: false,
      onFocusChange: (focused) {
        if (_focused == focused) return;
        setState(() => _focused = focused);
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onSecondaryTapDown: (details) =>
              _showContextMenu(details.globalPosition),
          onLongPressStart: (details) =>
              _showContextMenu(details.globalPosition),
          child: SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: _play,
                  child: SizedBox(
                    key: _posterKey,
                    width: width,
                    height: height,
                    child: PosterLift(
                      active: _active,
                      child: Stack(
                        fit: StackFit.expand,
                        clipBehavior: Clip.hardEdge,
                        children: [
                          MediaPoster(
                            media: widget.item.media,
                            posterUrlOverride: widget.item.displayPosterUrl,
                            width: width,
                            height: height,
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                          ),
                          PosterHoverOverlay(
                            active: _active,
                            focused: _focused,
                            playSize: 54,
                          ),
                          if (widget.item.hasNewEpisode)
                            const Positioned(
                              top: PosterCard.overlayInset,
                              left: PosterCard.overlayInset,
                              child: _NewEpisodeBadge(),
                            ),
                          // Même retrait que le badge ci-dessus, et le même que sur
                          // les affiches du catalogue : la barre flotte au lieu de se
                          // faire découper par l'arrondi du coin bas.
                          Positioned(
                            left: PosterCard.overlayInset,
                            right: PosterCard.overlayInset,
                            bottom: PosterCard.overlayInset,
                            child: ProgressPill(value: progress),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                MouseRegion(
                  cursor: widget.onTitleTap != null
                      ? SystemMouseCursors.click
                      : MouseCursor.defer,
                  child: GestureDetector(
                    onTap: widget.onTitleTap == null
                        ? null
                        : () => widget.onTitleTap!(_origin()),
                    behavior: HitTestBehavior.opaque,
                    child: Text(
                      widget.item.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
                if (detail != null)
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
                      height: 1.2,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String? _detailLine() {
    final remaining =
        widget.item.effectiveDuration - widget.item.currentPositionSeconds;
    final remainingStr =
        remaining > 0 ? '${formatDuration(remaining)} restantes' : null;

    if (widget.item.media.type == MediaType.episode) {
      final parts = <String>[];
      final epInfo = widget.item.continueWatchingSubtitle;
      if (epInfo != null) parts.add(epInfo);
      if (remainingStr != null) parts.add(remainingStr);
      return parts.isEmpty ? null : parts.join(' · ');
    }

    return remainingStr;
  }
}

/// Pastille « Nouvel épisode » posée sur l'affiche d'une série dont l'épisode à
/// reprendre vient de sortir. Fond plein plutôt que teinté : elle doit tenir
/// sur n'importe quelle affiche, claire comme sombre.
class _NewEpisodeBadge extends StatelessWidget {
  const _NewEpisodeBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_new_rounded, size: 13, color: AppColors.onAccent),
          SizedBox(width: 4),
          Text(
            'Nouvel épisode',
            style: TextStyle(
              color: AppColors.onAccent,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}
