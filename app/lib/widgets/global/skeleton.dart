import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import '../../utils/responsive.dart';
import 'poster_card.dart';

/// Les formes de ce qui arrive, pendant qu'il arrive.
///
/// Un chargement était un indicateur circulaire au milieu d'un écran vide, puis
/// la grille entière d'un coup : la page sautait d'une mise en page à l'autre.
/// Le squelette tient la mise en page dès la première image, et le contenu
/// vient se poser dedans.
///
/// La pulsation est un fondu d'opacité : sous « réduire les animations » elle
/// reste, comme tout fondu ([AppMotion.fade]), mais elle ralentit de moitié.
class SkeletonPulse extends StatefulWidget {
  final Widget child;

  const SkeletonPulse({super.key, required this.child});

  @override
  State<SkeletonPulse> createState() => _SkeletonPulseState();
}

class _SkeletonPulseState extends State<SkeletonPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = Duration(
      milliseconds: AppMotion.reduced(context) ? 2200 : 1100,
    );
    if (!_controller.isAnimating) _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: widget.child,
    );
  }
}

/// Un bloc de squelette.
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double? height;
  final double radius;

  const SkeletonBox({super.key, this.width, this.height, this.radius = 6});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// La silhouette d'une [PosterCard] : l'affiche, le titre, la ligne dessous.
class PosterCardSkeleton extends StatelessWidget {
  final bool compact;

  const PosterCardSkeleton({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Expanded(child: SkeletonBox(radius: PosterCard.radius)),
        SizedBox(height: compact ? 9 : 11),
        const FractionallySizedBox(
          widthFactor: 0.75,
          child: SkeletonBox(height: 12, radius: 4),
        ),
        const SizedBox(height: 6),
        const FractionallySizedBox(
          widthFactor: 0.35,
          child: SkeletonBox(height: 10, radius: 4),
        ),
      ],
    );
  }
}

/// Une grille d'affiches en squelette, à la place de la grille qui charge.
class PosterGridSkeleton extends StatelessWidget {
  final int count;

  const PosterGridSkeleton({super.key, this.count = 18});

  @override
  Widget build(BuildContext context) {
    final compact = AppLayout.isCompact(context);
    return SliverLayoutBuilder(
      builder: (context, constraints) => SliverGrid(
        gridDelegate: AppLayout.posterGridDelegate(
          constraints.crossAxisExtent,
          compact: compact,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => SkeletonPulse(
            child: PosterCardSkeleton(compact: compact),
          ),
          childCount: count,
        ),
      ),
    );
  }
}

/// L'accueil pendant qu'il charge : le bandeau, puis deux rangées d'affiches.
class HomeSkeleton extends StatelessWidget {
  /// Hauteur du bandeau, celle de `HeroBanner.heightFor`.
  final double heroHeight;

  const HomeSkeleton({super.key, required this.heroHeight});

  @override
  Widget build(BuildContext context) {
    final pad = AppLayout.pagePadding(context);
    final compact = AppLayout.isCompact(context);
    final cardWidth = compact ? 118.0 : 150.0;
    final cardHeight = cardWidth * 1.5;

    Widget row() => Padding(
          padding: EdgeInsets.fromLTRB(pad, 32, 0, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SkeletonBox(width: 180, height: 18, radius: 4),
              const SizedBox(height: 16),
              SizedBox(
                height: cardHeight + 40,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: 10,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (_, __) => SizedBox(
                    width: cardWidth,
                    child: PosterCardSkeleton(compact: compact),
                  ),
                ),
              ),
            ],
          ),
        );

    return SkeletonPulse(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: [
          SizedBox(
            height: heroHeight,
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, 0, pad, compact ? 52 : 84),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SkeletonBox(width: 60, height: 10, radius: 3),
                  const SizedBox(height: 14),
                  SkeletonBox(
                      width: compact ? 220 : 380, height: 40, radius: 6),
                  const SizedBox(height: 16),
                  SkeletonBox(
                      width: compact ? 260 : 460, height: 14, radius: 4),
                  const SizedBox(height: 8),
                  SkeletonBox(
                      width: compact ? 200 : 380, height: 14, radius: 4),
                  const SizedBox(height: 24),
                  const SkeletonBox(width: 150, height: 48, radius: 12),
                ],
              ),
            ),
          ),
          row(),
          row(),
        ],
      ),
    );
  }
}
