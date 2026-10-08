import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'interface_tour/tour_anchor.dart';
import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../services/media_details_cache.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import '../../utils/format.dart';
import '../../utils/poster_url.dart';
import '../../tv/tv_mode.dart';
import 'app_network_image.dart';
import 'media_logo_display.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';
import '../../l10n/tr.dart';

class HeroBanner extends StatefulWidget {
  final Media media;
  final String? subtitle;
  final String? titleOverride;
  final String? backgroundUrlOverride;
  final String playLabel;
  final VoidCallback onPlay;
  final VoidCallback? onInfo;

  /// Le média dont on lit la fiche TMDB pour l'image de fond et le logo : la
  /// série pour un épisode, le média lui-même sinon.
  final int? detailsMediaId;

  final bool autofocusPlay;

  const HeroBanner({
    super.key,
    required this.media,
    this.subtitle,
    this.titleOverride,
    this.backgroundUrlOverride,
    this.playLabel = 'Lecture',
    required this.onPlay,
    this.onInfo,
    this.detailsMediaId,
    this.autofocusPlay = false,
  });

  static double heightFor(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final fraction = TvScope.of(context)
        ? 0.55
        : size.width < 600
            ? 0.55
            : 0.65;
    return (size.height * fraction).clamp(360.0, 580.0);
  }

  @override
  State<HeroBanner> createState() => _HeroBannerState();
}

class _HeroBannerState extends State<HeroBanner> {
  MediaDetails? _details;
  bool _detailsSettled = false;

  int get _detailsId => widget.detailsMediaId ?? widget.media.id;

  @override
  void initState() {
    super.initState();
    _resolveDetails();
  }

  @override
  void didUpdateWidget(covariant HeroBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.detailsMediaId != widget.detailsMediaId ||
        oldWidget.media.id != widget.media.id) {
      _resolveDetails();
    }
  }

  /// La fiche TMDB porte l'image de fond en paysage et le logo du titre. Le
  /// bandeau étirait jusqu'ici l'affiche — un portrait 2:3 recadré en 16:9,
  /// agrandi jusqu'au flou, visages coupés — sous un titre en texte brut.
  void _resolveDetails() {
    final id = _detailsId;
    _details = MediaDetailsCache.peek(id);
    _detailsSettled = _details != null || id <= 0;
    if (_detailsSettled) return;
    final api = Provider.of<ApiClient>(context, listen: false);
    MediaDetailsCache.load(api, id).then((details) {
      if (!mounted || id != _detailsId) return;
      setState(() {
        _details = details;
        _detailsSettled = true;
      });
    }, onError: (_) {
      if (!mounted || id != _detailsId) return;
      setState(() => _detailsSettled = true);
    });
  }

  String? _backgroundUrl(String baseUrl) {
    final media = widget.media;
    // Un épisode a déjà son image en paysage : l'arrêt sur image de
    // l'épisode, plus parlant que le fond générique de la série.
    if (media.type == MediaType.episode &&
        widget.backgroundUrlOverride != null) {
      return widget.backgroundUrlOverride;
    }
    final backdrop = _details?.backdropUrl;
    if (backdrop != null && backdrop.isNotEmpty) {
      return backdropImageUrl(backdrop, serverBaseUrl: baseUrl);
    }
    // Tant que la fiche n'a pas répondu, rien plutôt que l'affiche : elle
    // serait remplacée une demi-seconde plus tard par une autre image.
    if (!_detailsSettled) return null;
    return widget.backgroundUrlOverride ??
        resolveHeroImageUrl(media.posterUrl, serverBaseUrl: baseUrl);
  }

  @override
  Widget build(BuildContext context) {
    final apiClient = Provider.of<ApiClient>(context, listen: false);
    final media = widget.media;
    final backgroundUrl = _backgroundUrl(apiClient.baseUrl);
    final title = widget.titleOverride ?? media.title;
    final year = extractYear(media.releaseDate);
    final meta = [
      if (year != null) year,
      if (widget.subtitle != null && widget.subtitle!.isNotEmpty)
        widget.subtitle!,
    ];
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isCompact = screenWidth < 600;
    final horizontalPadding = isCompact ? 16.0 : 48.0;
    final bannerHeight = HeroBanner.heightFor(context);
    final detailsOverview = _details?.overview;
    final overview = media.type != MediaType.episode &&
            detailsOverview != null &&
            detailsOverview.isNotEmpty
        ? detailsOverview
        : media.overview;

    return SizedBox(
      height: bannerHeight,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: AppColors.background),
          if (backgroundUrl != null)
            AppNetworkImage(
              url: backgroundUrl,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              filterQuality: FilterQuality.high,
              // Logical width — AppNetworkImage applies the device pixel ratio.
              decodeWidth: screenWidth,
              fadeInDuration: AppMotion.emphasis,
              placeholder: const ColoredBox(color: AppColors.background),
              errorWidget: const ColoredBox(color: AppColors.background),
            ),

          // Le voile latéral d'abord, le vertical ensuite, et tous deux vers
          // la couleur de la page : peint en noir pur par-dessus le fondu
          // vertical, le voile latéral laissait une marche visible entre le
          // bas du bandeau et la première rangée.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  AppColors.background
                      .withValues(alpha: isCompact ? 0.55 : 0.9),
                  AppColors.background
                      .withValues(alpha: isCompact ? 0.2 : 0.45),
                  AppColors.background.withValues(alpha: 0),
                ],
                stops: const [0.0, 0.4, 0.75],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  // Un voile en haut, pour que l'en-tête reste lisible sur un
                  // fond clair.
                  AppColors.background.withValues(alpha: 0.45),
                  AppColors.background.withValues(alpha: 0),
                  AppColors.background.withValues(alpha: 0.35),
                  AppColors.background,
                ],
                stops: const [0.0, 0.25, 0.6, 1.0],
              ),
            ),
          ),

          Positioned(
            left: horizontalPadding,
            right: horizontalPadding,
            bottom: isCompact ? 52 : 84,
            // L'Align relâche la largeur imposée par le Positioned : sans lui,
            // la limite de 560 px était ignorée et le synopsis courait sur toute
            // la largeur de l'écran.
            child: Align(
              alignment: Alignment.bottomLeft,
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(maxWidth: isCompact ? double.infinity : 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      mediaTypeLabel(media.type).toUpperCase(),
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: AppType.caption,
                        letterSpacing: 1.6,
                      ),
                    ),
                    const SizedBox(height: 12),
                    MediaLogoDisplay(
                      title: title,
                      logoUrl: logoImageUrl(_details?.logoUrl,
                          serverBaseUrl: apiClient.baseUrl),
                      maxHeight: isCompact ? 72 : 128,
                      maxWidth: isCompact ? screenWidth * 0.8 : 560,
                      textStyle:
                          Theme.of(context).textTheme.displaySmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                fontSize: isCompact ? 30 : 44,
                                height: 1.05,
                                letterSpacing: isCompact ? -0.6 : -1.0,
                              ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        meta.join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: AppType.body,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    if (overview != null && overview.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        overview,
                        maxLines: isCompact ? 2 : 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: AppType.callout,
                          height: 1.5,
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    TourTarget(
                      anchor: TourAnchor.hero,
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          _PlayButton(
                            label: tr(widget.playLabel),
                            onPressed: widget.onPlay,
                            autofocus: widget.autofocusPlay,
                          ),
                          if (widget.onInfo != null)
                            _InfoButton(
                              onPressed: widget.onInfo!,
                              compact: isCompact,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final bool autofocus;

  const _PlayButton({
    required this.label,
    required this.onPressed,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      autofocus: autofocus,
      icon: const Icon(AppIcons.play, size: 28),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
      ),
    );
  }
}

class _InfoButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool compact;

  const _InfoButton({required this.onPressed, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(AppIcons.info, size: 22),
      label: Text(compact ? tr('Infos') : tr('Plus d’infos')),
      style: OutlinedButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: 0.15),
        side: BorderSide.none,
        minimumSize: const Size(48, 48),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 16 : 24,
          vertical: 14,
        ),
      ),
    );
  }
}
