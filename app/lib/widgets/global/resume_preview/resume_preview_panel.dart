import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/tr.dart';
import '../../../models/models.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_icons.dart';
import '../../../theme/app_motion.dart';
import '../../../theme/app_type.dart';
import '../../../utils/on_screen.dart';
import '../../../utils/poster_url.dart';
import '../app_network_image.dart';
import '../poster_card.dart';
import '../poster_more_button.dart';
import '../progress_pill.dart';
import 'resume_preview_stills.dart';

/// La carte agrandie d'un élément de « Reprendre » : un diaporama des images
/// qui précèdent l'arrêt, le titre, l'épisode, le temps restant et le résumé.
class ResumePreviewPanel extends StatelessWidget {
  const ResumePreviewPanel({
    super.key,
    required this.item,
    required this.stills,
    required this.detail,
    required this.onPlay,
    this.onDetails,
    this.onMenu,
  });

  static const double width = 340;

  final HomeMediaItem item;
  final ResumePreviewStills stills;

  /// La ligne sous le titre de la carte (épisode, temps restant), reprise
  /// telle quelle pour que les deux disent la même chose.
  final String? detail;
  final VoidCallback onPlay;
  final VoidCallback? onDetails;

  /// Le menu de la carte (fiche, marquer comme vu, retirer), ouvert à ce
  /// point de l'écran. L'aperçu recouvre le « ⋯ » de la carte : il porte le
  /// sien au même coin.
  final Future<void> Function(Offset globalPosition)? onMenu;

  @override
  Widget build(BuildContext context) {
    final overview = item.media.overview?.trim() ?? '';
    return Material(
      color: AppColors.surfaceElevated,
      elevation: 16,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: onPlay,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _Slideshow(
                          stills: stills, fallbackUrl: _fallbackUrl(context)),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: [0.55, 1],
                            colors: [
                              AppColors.gradientTop,
                              AppColors.surfaceElevated,
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 14,
                        right: 14,
                        bottom: 8,
                        child: ProgressPill(value: item.percentWatched),
                      ),
                      if (onMenu != null)
                        Positioned(
                          top: PosterCard.overlayInset - 4,
                          right: PosterCard.overlayInset - 4,
                          child: PosterMoreButton(
                            onPressed: (buttonContext) {
                              final anchor =
                                  PosterMoreButton.menuAnchor(buttonContext);
                              if (anchor != null) onMenu!(anchor);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: AppType.headline,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: AppType.footnote,
                        height: 1.3,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: onPlay,
                        icon: const Icon(AppIcons.play, size: 18),
                        label: Text(tr('Reprendre')),
                      ),
                      if (onDetails != null) ...[
                        const SizedBox(width: 8),
                        IconButton.outlined(
                          tooltip: tr('Voir la fiche'),
                          onPressed: onDetails,
                          icon: const Icon(AppIcons.info, size: 20),
                        ),
                      ],
                    ],
                  ),
                  if (overview.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      overview,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: AppType.subhead,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Ce qui tient la place des images tant qu'elles n'ont pas répondu. Pour
  /// un épisode, l'affiche du média est la vignette de l'épisode, déjà au
  /// format 16:9 ; pour un film, c'est l'affiche, recadrée.
  String? _fallbackUrl(BuildContext context) {
    final resolved = resolvePosterUrl(
      item.media.posterUrl ?? item.displayPosterUrl,
      serverBaseUrl: Provider.of<ApiClient>(context, listen: false).baseUrl,
    );
    return resolved == null ? null : tmdbSizedUrl(resolved, 'w780');
  }
}

/// Les images en fondu, chacune avec une lente avancée vers l'avant : c'est
/// ce qui la fait lire comme un extrait plutôt que comme une photo.
class _Slideshow extends StatefulWidget {
  const _Slideshow({required this.stills, required this.fallbackUrl});

  final ResumePreviewStills stills;
  final String? fallbackUrl;

  @override
  State<_Slideshow> createState() => _SlideshowState();
}

class _SlideshowState extends State<_Slideshow> with OnScreenState<_Slideshow> {
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    widget.stills.addListener(_changed);
  }

  /// Le diaporama n'avance que tant qu'on le voit : fenêtre réduite, il
  /// réveillerait l'app pour rien.
  @override
  void didChangeOnScreen(bool onScreen) {
    _timer?.cancel();
    _timer =
        onScreen ? Timer.periodic(AppMotion.ambient, (_) => _advance()) : null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.stills.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _advance() {
    final count = widget.stills.images.length;
    if (count < 2 || !mounted) return;
    setState(() => _index = (_index + 1) % count);
  }

  @override
  Widget build(BuildContext context) {
    final images = widget.stills.images;
    final Widget child = images.isEmpty
        ? AppNetworkImage(
            key: const ValueKey('fallback'),
            url: widget.fallbackUrl,
            alignment: const Alignment(0, -0.4),
            decodeWidth: ResumePreviewPanel.width,
          )
        : _Drift(
            key: ValueKey(_index % images.length),
            child: Image(
              image: images[_index % images.length],
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          );
    return AnimatedSwitcher(
      duration: AppMotion.fade(context, AppMotion.emphasis),
      switchInCurve: AppMotion.curve,
      switchOutCurve: AppMotion.curve,
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: [...previous, if (current != null) current],
      ),
      child: child,
    );
  }
}

class _Drift extends StatelessWidget {
  const _Drift({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1, end: 1.06),
      duration: AppMotion.move(context, AppMotion.ambient),
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: child,
    );
  }
}
