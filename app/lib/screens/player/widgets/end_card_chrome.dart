import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../widgets/global/app_network_image.dart';

/// Shared chrome of the pages that close an episode: the end-of-season request
/// ([NextSeasonOverlay]) and the episode a season is still waiting for
/// ([UpcomingEpisodeOverlay]).
///
/// Both occupy the space left free by the shrunk video rather than floating
/// over it — the credits stay watchable to the left while this reads as a full
/// panel, the way Crunchyroll and Netflix end a season. Neither ever acts on
/// its own: no countdown, no auto-advance, always a tap.
class EndCardPanel extends StatelessWidget {
  /// Artwork washed and blurred behind the panel, so the page has a colour of
  /// its own instead of sitting on flat black.
  final String? backdropUrl;

  final Widget eyebrow;
  final Widget body;
  final Widget actions;

  /// Width reserved on the left for the shrunk video.
  final double videoInset;

  const EndCardPanel({
    super.key,
    required this.eyebrow,
    required this.body,
    required this.actions,
    this.backdropUrl,
    this.videoInset = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      bottom: 0,
      left: videoInset,
      right: 0,
      child: Material(
        color: Colors.transparent,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (context, t, child) {
            return Opacity(
              opacity: t.clamp(0, 1),
              child: Transform.translate(
                offset: Offset(28 * (1 - t), 0),
                child: child,
              ),
            );
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              _Backdrop(url: backdropUrl),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(40, 28, 44, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      eyebrow,
                      const Spacer(),
                      Flexible(
                        flex: 8,
                        child: SingleChildScrollView(child: body),
                      ),
                      const Spacer(),
                      actions,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Backdrop extends StatelessWidget {
  final String? url;

  const _Backdrop({required this.url});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (url != null)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
            child: Opacity(
              opacity: 0.32,
              child: AppNetworkImage(
                // 60px of blur — a small decode is indistinguishable here, and
                // this overlay appears mid-playback where nothing may stutter.
                url: url,
                fit: BoxFit.cover,
                decodeWidth: 320,
                placeholder: const SizedBox.shrink(),
                errorWidget: const SizedBox.shrink(),
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                AppColors.background,
                AppColors.background.withValues(alpha: 0.92),
                AppColors.background.withValues(alpha: 0.78),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The one-line status the page opens on, plus its way out.
class EndCardEyebrow extends StatelessWidget {
  final String label;
  final VoidCallback onDismiss;

  const EndCardEyebrow({
    super.key,
    required this.label,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
            color: AppColors.accent,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 2.2,
            ),
          ),
        ),
        _CloseButton(onTap: onDismiss),
      ],
    );
  }
}

class _CloseButton extends StatefulWidget {
  final VoidCallback onTap;

  const _CloseButton({required this.onTap});

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hovered ? AppColors.surfaceHover : Colors.transparent,
            border: Border.all(
              color: _hovered ? AppColors.border : Colors.transparent,
            ),
          ),
          child: Icon(
            Icons.close_rounded,
            size: 18,
            color: _hovered ? AppColors.textPrimary : AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}

/// One fact about what comes next — an episode count, a date, a state.
class EndCardPill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool accent;

  const EndCardPill({
    super.key,
    required this.label,
    this.icon,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = accent ? AppColors.accentMuted : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: AppColors.surfaceElevated.withValues(alpha: 0.7),
        border: Border.all(
          color: accent ? AppColors.primary : AppColors.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Poster or still standing beside the text, shadowed off the backdrop.
class EndCardArtwork extends StatelessWidget {
  final String url;
  final double width;
  final double height;

  const EndCardArtwork({
    super.key,
    required this.url,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.55),
              blurRadius: 32,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: AppNetworkImage(
          url: url,
          width: width,
          height: height,
          fit: BoxFit.cover,
          errorWidget: const SizedBox.shrink(),
        ),
      ),
    );
  }
}

/// Way out of an end card towards the episode that still follows, so the page's
/// own question and watching on stay two independent choices.
class EndCardNextEpisodeButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool primary;
  final bool enabled;

  const EndCardNextEpisodeButton({
    super.key,
    required this.onTap,
    required this.primary,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    const label = Text('Épisode suivant');
    const icon = Icon(Icons.skip_next_rounded, size: 19);
    final padding = EdgeInsets.symmetric(
      horizontal: primary ? 28 : 22,
      vertical: primary ? 20 : 18,
    );
    const textStyle = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );

    if (primary) {
      return ElevatedButton.icon(
        onPressed: enabled ? onTap : null,
        style: ElevatedButton.styleFrom(
          padding: padding,
          shape: shape,
          textStyle: textStyle,
        ),
        icon: icon,
        label: label,
      );
    }

    return OutlinedButton.icon(
      onPressed: enabled ? onTap : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        side: const BorderSide(color: AppColors.border),
        padding: padding,
        shape: shape,
        textStyle: textStyle,
      ),
      icon: icon,
      label: label,
    );
  }
}
