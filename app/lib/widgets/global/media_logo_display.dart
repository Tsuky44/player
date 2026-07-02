import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// TMDB title logo (`images.logos`) when available, plain title otherwise —
/// same approach as MediaHub's [MediaTitleHeader].
class MediaLogoDisplay extends StatelessWidget {
  final String title;
  final String? logoUrl;
  final double maxHeight;
  final double? maxWidth;
  final TextStyle? textStyle;

  const MediaLogoDisplay({
    super.key,
    required this.title,
    this.logoUrl,
    this.maxHeight = 140,
    this.maxWidth,
    this.textStyle,
  });

  bool get _hasLogo => logoUrl != null && logoUrl!.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final width = maxWidth ?? 420;

    if (_hasLogo) {
      // Explicit width is required — without it the image can collapse to 0px.
      return SizedBox(
        width: width,
        child: DecoratedBox(
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.55),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: CachedNetworkImage(
            imageUrl: logoUrl!,
            width: width,
            height: maxHeight,
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
            filterQuality: FilterQuality.high,
            placeholder: (_, __) => SizedBox(
              width: width,
              height: maxHeight * 0.6,
              child: const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
            errorWidget: (_, __, ___) => _TitleFallback(
              title: title,
              maxHeight: maxHeight,
              maxWidth: width,
              style: textStyle,
            ),
          ),
        ),
      );
    }

    return _TitleFallback(
      title: title,
      maxHeight: maxHeight,
      maxWidth: width,
      style: textStyle,
    );
  }
}

class _TitleFallback extends StatelessWidget {
  final String title;
  final double maxHeight;
  final double? maxWidth;
  final TextStyle? style;

  const _TitleFallback({
    required this.title,
    required this.maxHeight,
    this.maxWidth,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final effective = style ??
        TextStyle(
          fontSize: (maxHeight * 0.42).clamp(22.0, 56.0),
          fontWeight: FontWeight.w800,
          height: 1.05,
          color: Colors.white,
          shadows: [
            Shadow(
              color: Colors.black.withValues(alpha: 0.55),
              blurRadius: 14,
            ),
          ],
        );

    return SizedBox(
      width: maxWidth,
      child: Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: effective,
      ),
    );
  }
}
