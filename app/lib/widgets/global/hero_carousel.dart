import 'dart:async';
import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../utils/hero_slides.dart';
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

class _HeroCarouselState extends State<HeroCarousel> {
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
    _scheduleAutoAdvance();
  }

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

  void _scheduleAutoAdvance() {
    _autoTimer?.cancel();
    if (widget.slides.length <= 1 || _hovered || _focused) return;

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

    final screenHeight = MediaQuery.sizeOf(context).height;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isCompact = screenWidth < 600;
    final bannerHeight =
        (screenHeight * (isCompact ? 0.55 : 0.65)).clamp(360.0, 580.0);

    return Focus(
      // A pure observer: it reports that something below it holds the focus,
      // and never takes it itself.
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        _focused = focused;
        _scheduleAutoAdvance();
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
                left: 0,
                right: 0,
                bottom: isCompact ? 18 : 28,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(widget.slides.length, (index) {
                    final active = index == _currentIndex;
                    return GestureDetector(
                      onTap: () => _pageController.animateToPage(
                        index,
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeInOut,
                      ),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        width: active ? 22 : 8,
                        height: 8,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: active
                              ? AppColors.textPrimary
                              : AppColors.textMuted.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(4),
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
    );
  }
}
