import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_colors.dart';
import '../../utils/hero_slides.dart';
import '../../utils/on_screen.dart';
import 'hero_banner.dart';

class HeroCarousel extends StatefulWidget {
  final List<HeroSlide> slides;
  final void Function(HeroSlide slide) onPlay;
  final void Function(HeroSlide slide)? onInfo;

  /// Gives the visible slide's play button the first focus. Television only —
  /// see [HeroBanner.autofocusPlay].
  final bool autofocusPlay;

  const HeroCarousel({
    super.key,
    required this.slides,
    required this.onPlay,
    this.onInfo,
    this.autofocusPlay = false,
  });

  @override
  State<HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<HeroCarousel> with OnScreenState {
  static const _autoInterval = Duration(seconds: 7);

  late final PageController _pageController;
  Timer? _autoTimer;
  int _currentIndex = 0;
  bool _hovered = false;

  /// The remote is on the banner. Auto-advance stops for the same reason it
  /// stops under the mouse — and for a harder one: the slide it would turn to
  /// rebuilds the page the focused button lives on, and the focus goes with it.
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  /// Le carrousel n'avance que sous les yeux de quelqu'un : caché sous le
  /// lecteur, dans un autre onglet ou fenêtre réduite, chaque diapositive
  /// relançait une transition d'une seconde que personne ne voyait.
  @override
  void didChangeOnScreen(bool onScreen) => _scheduleAutoAdvance();

  @override
  void didUpdateWidget(covariant HeroCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slides.length != widget.slides.length) {
      _currentIndex = 0;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
      _scheduleAutoAdvance();
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  /// Un doigt s'est posé sur le bandeau : il ne repart plus tout seul. Au
  /// tactile il n'y a pas de survol pour le suspendre, et le mouvement était
  /// inarrêtable.
  bool _touched = false;

  void _scheduleAutoAdvance() {
    _autoTimer?.cancel();
    if (widget.slides.length <= 1 ||
        _hovered ||
        _focused ||
        _touched ||
        !isOnScreen ||
        // « Réduire les animations » : un fond plein écran qui défile seul
        // est exactement ce que ce réglage demande d'éviter.
        AppMotion.reduced(context)) {
      return;
    }

    _autoTimer = Timer.periodic(_autoInterval, (_) {
      if (!mounted || _hovered || _focused || widget.slides.length <= 1) return;
      final next = (_currentIndex + 1) % widget.slides.length;
      _pageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 900),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
    _scheduleAutoAdvance();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.slides.isEmpty) return const SizedBox.shrink();

    final screenWidth = MediaQuery.sizeOf(context).width;
    final isCompact = screenWidth < 600;
    final bannerHeight = HeroBanner.heightFor(context);

    return Focus(
      // A pure observer: it reports that something below it holds the focus,
      // and never takes it itself.
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        _focused = focused;
        _scheduleAutoAdvance();
      },
      child: Listener(
        onPointerDown: (event) {
          if (event.kind != PointerDeviceKind.touch || _touched) return;
          _touched = true;
          _autoTimer?.cancel();
        },
        child: MouseRegion(
          onEnter: (_) {
            _hovered = true;
            _autoTimer?.cancel();
          },
          onExit: (_) {
            _hovered = false;
            _scheduleAutoAdvance();
          },
          child: SizedBox(
            height: bannerHeight,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                PageView.builder(
                  controller: _pageController,
                  itemCount: widget.slides.length,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, index) {
                    final slide = widget.slides[index];
                    return HeroBanner(
                      media: slide.media,
                      titleOverride: slide.title,
                      subtitle: slide.subtitle,
                      backgroundUrlOverride: slide.backgroundUrl,
                      detailsMediaId: slide.media.type == MediaType.episode
                          ? slide.continueItem?.showId
                          : slide.media.id,
                      playLabel: slide.playLabel,
                      onPlay: () => widget.onPlay(slide),
                      onInfo: slide.showInfoButton && widget.onInfo != null
                          ? () => widget.onInfo!(slide)
                          : null,
                      // Only the slide on screen: an autofocus on a page the
                      // PageView has built ahead would pull the focus off-screen.
                      autofocusPlay: widget.autofocusPlay && index == 0,
                    );
                  },
                ),
                if (widget.slides.length > 1)
                  Positioned(
                    // Alignés sur le texte du bandeau, pas centrés sous un
                    // contenu qui, lui, est calé à gauche.
                    left: isCompact ? 16 : 48,
                    bottom: isCompact ? 20 : 36,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: List.generate(widget.slides.length, (index) {
                        final active = index == _currentIndex;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _pageController.animateToPage(
                            index,
                            duration:
                                AppMotion.move(context, AppMotion.emphasis),
                            curve: AppMotion.curve,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 3, vertical: 10),
                            child: AnimatedContainer(
                              duration: AppMotion.move(context),
                              curve: AppMotion.curve,
                              width: active ? 20 : 6,
                              height: 3,
                              decoration: BoxDecoration(
                                color: active
                                    ? AppColors.textPrimary
                                    : AppColors.textPrimary
                                        .withValues(alpha: 0.28),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
