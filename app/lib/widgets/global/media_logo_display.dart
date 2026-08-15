import 'package:flutter/material.dart';

import 'app_network_image.dart';

/// TMDB title logo (`images.logos`) when available, plain title otherwise —
/// same approach as MediaHub's [MediaTitleHeader].
///
/// The URL is expected to be normalised through `logoImageUrl` so that every
/// surface drawing this title's logo — detail header, player chrome — asks for
/// the same bytes and the second one draws from cache.
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

    if (!_hasLogo) {
      return _TitleFallback(
        title: title,
        maxHeight: maxHeight,
        maxWidth: width,
        style: textStyle,
      );
    }

    final fallback = _TitleFallback(
      title: title,
      maxHeight: maxHeight,
      maxWidth: width,
      style: textStyle,
    );

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
        child: AppNetworkImage(
          url: logoUrl,
          width: width,
          height: maxHeight,
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
          filterQuality: FilterQuality.high,
          // Logos are small at w500 and several screens draw them at different
          // heights. An unconstrained decode keeps one entry in the memory
          // cache that all of them hit, instead of one per slot size.
          decodeAtSourceSize: true,
          // The title holds the slot while the logo is in flight — the spinner
          // that used to sit here was a second layout state on a header that
          // already had one, and it flashed on every cached hit.
          placeholder: fallback,
          errorWidget: fallback,
        ),
      ),
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
