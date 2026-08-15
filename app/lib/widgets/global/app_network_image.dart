import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/app_image_cache.dart';
import '../../theme/app_colors.dart';

/// Every remote image in the app goes through here.
///
/// Three things it guarantees that scattered `CachedNetworkImage` /
/// `Image.network` calls did not:
///
/// * **one store** — the shared [AppImageCache] manager, so the same URL drawn
///   on a card, a detail header and the player chrome is downloaded once;
/// * **a bounded decode** — full-size artwork decoded at slot size instead of
///   source size, which is what kept large backdrops off the first frame;
/// * **a placeholder that occupies the final box**, so nothing reflows when the
///   bytes land.
class AppNetworkImage extends StatelessWidget {
  /// Fully resolved URL. Null/empty renders [errorWidget].
  final String? url;

  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;

  /// Shown while the bytes are in flight. Defaults to a flat surface fill,
  /// which reads as part of the layout instead of as a missing image.
  final Widget? placeholder;

  /// Shown when the URL is absent or the fetch failed.
  final Widget? errorWidget;

  final Duration fadeInDuration;
  final FilterQuality filterQuality;

  /// Logical width the image is drawn at, when [width] is not the answer —
  /// e.g. a `BoxFit.cover` backdrop inside an expanded Stack. Null means "ask
  /// the layout", and a null answer means "decode at source size".
  final double? decodeWidth;

  /// Opts out of the bounded decode. Used for small artwork (title logos) that
  /// several screens draw at different sizes: an unconstrained decode keeps one
  /// entry in the memory cache that all of them hit.
  final bool decodeAtSourceSize;

  final Color? color;
  final BlendMode? colorBlendMode;

  const AppNetworkImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.placeholder,
    this.errorWidget,
    this.fadeInDuration = const Duration(milliseconds: 180),
    this.filterQuality = FilterQuality.medium,
    this.decodeWidth,
    this.decodeAtSourceSize = false,
    this.color,
    this.colorBlendMode,
  });

  /// Decode widths are rounded up to this many device pixels.
  ///
  /// `memCacheWidth` is part of the image's cache key, so a width taken
  /// verbatim from the layout would give a responsive grid a separate decode
  /// per breakpoint — and per hairline rounding difference. Quantising means a
  /// handful of shared buckets instead.
  static const int _decodeStep = 128;

  static int? _decodeWidthFor(double? logicalWidth, double devicePixelRatio) {
    if (logicalWidth == null ||
        !logicalWidth.isFinite ||
        logicalWidth <= 0) {
      return null;
    }
    final physical = logicalWidth * devicePixelRatio;
    final stepped = (physical / _decodeStep).ceil() * _decodeStep;
    return stepped.clamp(_decodeStep, 4096).toInt();
  }

  @override
  Widget build(BuildContext context) {
    final resolved = url?.trim();
    if (resolved == null || resolved.isEmpty) return _error();

    if (decodeAtSourceSize) return _image(context, null);

    final explicit = decodeWidth ?? width;
    if (explicit != null) {
      return _image(
        context,
        _decodeWidthFor(explicit, MediaQuery.devicePixelRatioOf(context)),
      );
    }

    // No width was given, so the slot decides. Falling back to a source-size
    // decode when the box is unbounded keeps this from ever failing to draw.
    return LayoutBuilder(
      builder: (context, constraints) => _image(
        context,
        _decodeWidthFor(
          constraints.hasBoundedWidth ? constraints.maxWidth : null,
          MediaQuery.devicePixelRatioOf(context),
        ),
      ),
    );
  }

  Widget _image(BuildContext context, int? memCacheWidth) {
    return CachedNetworkImage(
      imageUrl: url!.trim(),
      cacheManager: AppImageCache.imageCacheManager,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      color: color,
      colorBlendMode: colorBlendMode,
      filterQuality: filterQuality,
      fadeInDuration: fadeInDuration,
      // A cached hit should appear on the frame it is requested, with no
      // cross-fade from the placeholder.
      fadeOutDuration: const Duration(milliseconds: 80),
      memCacheWidth: memCacheWidth,
      placeholder: (_, __) => _placeholder(),
      errorWidget: (_, __, ___) => _error(),
    );
  }

  Widget _placeholder() =>
      placeholder ??
      SizedBox(
        width: width,
        height: height,
        child: const ColoredBox(color: AppColors.surfaceElevated),
      );

  Widget _error() =>
      errorWidget ??
      SizedBox(
        width: width,
        height: height,
        child: const ColoredBox(color: AppColors.surfaceElevated),
      );
}
