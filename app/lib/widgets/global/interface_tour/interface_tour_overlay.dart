import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../l10n/tr.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_motion.dart';
import '../../../theme/app_type.dart';
import '../../../tv/tv_mode.dart';
import '../../../utils/responsive.dart';
import '../glass_chrome.dart';
import 'interface_tour.dart';
import 'tour_anchor.dart';

/// La présentation elle-même : un voile sur l'écran, une loupe de verre posée
/// sur la zone dont on parle, et une carte qui l'explique.
///
/// Un appui n'importe où passe à la suite ; « Passer » ferme tout. La loupe
/// glisse d'une zone à l'autre en se déformant, plutôt que de disparaître et
/// de reparaître : c'est ce qui dit à l'œil où regarder ensuite.
class InterfaceTourOverlay extends StatefulWidget {
  /// Les étapes à jouer, la première sans zone.
  final List<InterfaceTourStep> steps;
  final TourAnchors anchors;

  /// Appelé une fois le voile retiré, que la présentation ait été finie ou
  /// passée.
  final VoidCallback onClose;

  const InterfaceTourOverlay({
    super.key,
    required this.steps,
    required this.anchors,
    required this.onClose,
  });

  @override
  State<InterfaceTourOverlay> createState() => _InterfaceTourOverlayState();
}

class _InterfaceTourOverlayState extends State<InterfaceTourOverlay>
    with SingleTickerProviderStateMixin {
  /// La marge laissée autour de la zone, pour que la loupe ne la serre pas.
  static const double _targetPadding = 8;

  late final AnimationController _move = AnimationController(
    vsync: this,
    duration: AppMotion.emphasis,
    value: 1,
  );
  late final Animation<double> _travel =
      CurvedAnimation(parent: _move, curve: AppMotion.curve);

  int _index = 0;

  /// D'où part et où va la loupe, dans le repère de l'overlay. `null` : aucune
  /// zone, la loupe est refermée au centre de l'écran.
  Rect? _from;
  Rect? _to;

  bool _closing = false;

  /// Vrai le temps que la page défile vers la zone suivante : un second appui
  /// pendant ce temps sauterait une étape.
  bool _advancing = false;
  Size? _measuredFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Une fenêtre redimensionnée déplace les zones : on les relit une fois la
    // nouvelle mise en page posée.
    final size = MediaQuery.sizeOf(context);
    if (_measuredFor == size) return;
    _measuredFor = size;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final anchor = widget.steps[_index].anchor;
      final rect = anchor == null ? null : _rectOf(anchor);
      if (rect == null || rect == _to) return;
      setState(() => _to = rect);
    });
  }

  @override
  void dispose() {
    _move.dispose();
    super.dispose();
  }

  /// La zone [anchor] dans le repère de l'overlay — qui n'est pas celui de la
  /// fenêtre sur un téléviseur, où la page est mise à l'échelle.
  Rect? _rectOf(TourAnchor anchor) {
    final global = widget.anchors.rectOf(anchor);
    final box = context.findRenderObject();
    if (global == null || box is! RenderBox) return null;
    final toLocal = Matrix4.tryInvert(box.getTransformTo(null));
    if (toLocal == null) return null;
    return MatrixUtils.transformRect(toLocal, global).inflate(_targetPadding);
  }

  Future<void> _next() async {
    if (_closing || _advancing) return;
    _advancing = true;
    try {
      await _advance();
    } finally {
      _advancing = false;
    }
  }

  Future<void> _advance() async {
    for (var i = _index + 1; i < widget.steps.length; i++) {
      final anchor = widget.steps[i].anchor;
      if (anchor != null) {
        // Une rangée de l'accueil peut être sous le bas de l'écran : la page
        // l'amène d'abord, la loupe la rejoint ensuite.
        await widget.anchors.reveal(
          anchor,
          duration: AppMotion.move(context),
          curve: AppMotion.curve,
        );
        if (!mounted || _closing) return;
      }
      final rect = anchor == null ? null : _rectOf(anchor);
      // Une zone partie entre-temps (la fenêtre a changé de gabarit) : on ne
      // montre pas du vide, on passe à la suivante.
      if (anchor != null && rect == null) continue;
      final size = context.size ?? Size.zero;
      setState(() {
        _from = Rect.lerp(
            _resolve(_from, size), _resolve(_to, size), _travel.value);
        _to = rect;
        _index = i;
      });
      if (AppMotion.reduced(context)) {
        _move.value = 1;
      } else {
        _move.forward(from: 0);
      }
      return;
    }
    _close();
  }

  void _close() {
    if (_closing) return;
    setState(() => _closing = true);
  }

  static Rect _resolve(Rect? rect, Size size) =>
      rect ?? (size.center(Offset.zero) & Size.zero);

  @override
  Widget build(BuildContext context) {
    final step = widget.steps[_index];
    final isLast = _index == widget.steps.length - 1;
    // Un flou plein écran sur un boîtier de salon est la dépense que
    // l'ADR-0025 demande d'éviter, et à trois mètres le voile seul suffit.
    final blurred = !TvScope.of(context);

    // Une route nue n'a pas de `Material` au-dessus d'elle : sans celui-ci,
    // le texte de la carte perd la police et les couleurs du thème.
    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _next,
        // Les lecteurs d'écran ont le bouton « Suivant » : ce geste-ci en serait
        // un double sans nom.
        excludeFromSemantics: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            final from = _resolve(_from, size);
            final to = _resolve(_to, size);

            return TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: _closing ? 0 : 1),
              duration: AppMotion.fade(context),
              curve: AppMotion.curve,
              onEnd: () {
                if (_closing) widget.onClose();
              },
              builder: (context, presence, _) => Stack(
                children: [
                  Positioned.fill(
                    child: AnimatedBuilder(
                      animation: _travel,
                      builder: (context, _) => _Spotlight(
                        target: Rect.lerp(from, to, _travel.value)!,
                        bounds: Offset.zero & size,
                        presence: presence,
                        blurred: blurred,
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: Opacity(
                      opacity: presence,
                      child: CustomSingleChildLayout(
                        delegate: _CardLayout(
                          from: _TourLens.around(from, Offset.zero & size).rect,
                          to: _TourLens.around(to, Offset.zero & size).rect,
                          travel: _travel,
                          safeArea: MediaQuery.paddingOf(context),
                        ),
                        child: _TourCard(
                          step: step,
                          index: _index,
                          count: widget.steps.length,
                          isLast: isLast,
                          onNext: _next,
                          onSkip: _close,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// La géométrie de la loupe pour une zone donnée.
class _TourLens {
  /// Où la loupe se pose.
  final Rect rect;

  /// Ce qu'elle grossit, et de combien.
  final Rect target;
  final double zoom;

  const _TourLens._(this.rect, this.target, this.zoom);

  /// Une petite zone (un bouton rond) est grossie franchement, une large (une
  /// rangée d'onglets) à peine : au même facteur, la première resterait un
  /// détail et la seconde déborderait de l'écran.
  static const double _zoomSmall = 1.3;
  static const double _zoomLarge = 1.12;
  static const double _smallSide = 56;
  static const double _largeSide = 120;

  /// La marge gardée avec le bord de l'écran.
  static const double _edge = 6;

  factory _TourLens.around(Rect target, Rect bounds) {
    final t = ((target.shortestSide - _smallSide) / (_largeSide - _smallSide))
        .clamp(0.0, 1.0);
    final zoom = lerpDouble(_zoomSmall, _zoomLarge, t)!;
    final width =
        math.max(0.0, math.min(target.width * zoom, bounds.width - 2 * _edge));
    final height = math.max(
        0.0, math.min(target.height * zoom, bounds.height - 2 * _edge));
    // Une zone collée au bord grossirait hors de l'écran : la loupe se décale
    // et vise de biais, comme une vraie.
    final center = Offset(
      _within(target.center.dx, bounds.left + _edge + width / 2,
          bounds.right - _edge - width / 2),
      _within(target.center.dy, bounds.top + _edge + height / 2,
          bounds.bottom - _edge - height / 2),
    );
    return _TourLens._(
      Rect.fromCenter(center: center, width: width, height: height),
      target,
      zoom,
    );
  }

  /// [value] ramené entre [low] et [high], ou à mi-chemin quand l'écran est
  /// trop petit pour qu'il y ait un entre-deux.
  static double _within(double value, double low, double high) =>
      low > high ? (low + high) / 2 : value.clamp(low, high).toDouble();

  bool get isOpen => target.shortestSide >= 2;

  /// Le superellipse d'Apple plutôt qu'un rectangle arrondi : c'est la forme
  /// qui se lit comme une goutte de verre et non comme un cadre.
  ShapeBorder shape({BorderSide side = BorderSide.none, double scale = 1}) =>
      RoundedSuperellipseBorder(
        side: side,
        borderRadius: BorderRadius.circular(
          math.min(22.0, rect.shortestSide / 2) * scale,
        ),
      );
}

/// Le voile, percé là où l'on regarde, et la loupe posée sur le trou.
class _Spotlight extends StatelessWidget {
  final Rect target;
  final Rect bounds;

  /// De 0 (absent) à 1 (posé) : l'entrée et la sortie de la présentation.
  final double presence;
  final bool blurred;

  const _Spotlight({
    required this.target,
    required this.bounds,
    required this.presence,
    required this.blurred,
  });

  @override
  Widget build(BuildContext context) {
    final lens = _TourLens.around(target, bounds);
    final veil = ColoredBox(
      color: Colors.black.withValues(alpha: 0.6 * presence),
      child: const SizedBox.expand(),
    );

    return Stack(
      children: [
        Positioned.fill(
          child: ClipPath(
            clipper: _VeilClipper(
              // Un rien plus large que ce que la loupe lit, pour que le bord
              // du voile n'entre pas dans l'image grossie.
              hole: lens.isOpen ? target.inflate(2) : null,
              shape: lens.shape(scale: 1 / lens.zoom),
            ),
            // Seul, hors du groupe de la coquille : ce voile couvre le chrome
            // et doit le flouter avec la page (ADR-0025).
            child: blurred
                ? BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: 12 * presence,
                      sigmaY: 12 * presence,
                    ),
                    child: veil,
                  )
                : veil,
          ),
        ),
        if (lens.isOpen)
          Positioned.fromRect(
            rect: lens.rect,
            child: IgnorePointer(
              child: RawMagnifier(
                size: lens.rect.size,
                magnificationScale: lens.zoom,
                focalPointOffset: target.center - lens.rect.center,
                decoration: MagnifierDecoration(
                  opacity: presence,
                  shape: lens.shape(),
                  // Plus courte que l'ombre ambiante des menus
                  // (`PROJECT_DESIGN.md` §10) : sur un voile déjà sombre,
                  // celle-ci se lisait comme une dalle sous la loupe.
                  shadows: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                // Le reflet : un filet clair et une lumière qui tombe du coin
                // haut, sans couleur — l'accent reste au focus.
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: lens.shape(
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.4),
                        width: 1.5,
                      ),
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withValues(alpha: 0.16),
                        Colors.white.withValues(alpha: 0),
                        Colors.white.withValues(alpha: 0.06),
                      ],
                      stops: const [0, 0.45, 1],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _VeilClipper extends CustomClipper<Path> {
  final Rect? hole;
  final ShapeBorder shape;

  const _VeilClipper({required this.hole, required this.shape});

  @override
  Path getClip(Size size) {
    final path = Path()..addRect(Offset.zero & size);
    final hole = this.hole;
    if (hole == null) return path;
    return path
      ..fillType = PathFillType.evenOdd
      ..addPath(shape.getOuterPath(hole), Offset.zero);
  }

  @override
  bool shouldReclip(_VeilClipper oldClipper) =>
      oldClipper.hole != hole || oldClipper.shape != shape;
}

/// Pose la carte contre la loupe : dessous quand il y a la place, dessus
/// sinon, et au centre de l'écran quand il n'y a pas de loupe.
///
/// La position se calcule aux deux bouts du trajet et s'interpole, plutôt que
/// de suivre la loupe : la carte changerait de côté d'un coup au milieu du
/// glissement entre une zone du haut et une zone du bas.
class _CardLayout extends SingleChildLayoutDelegate {
  final Rect from;
  final Rect to;
  final Animation<double> travel;
  final EdgeInsets safeArea;

  _CardLayout({
    required this.from,
    required this.to,
    required this.travel,
    required this.safeArea,
  }) : super(relayout: travel);

  static const double _maxWidth = 360;
  static const double _margin = 16;
  static const double _gap = 16;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width =
        math.max(0.0, constraints.maxWidth - 2 * _margin - safeArea.horizontal);
    return BoxConstraints(
      maxWidth: math.min(_maxWidth, width),
      maxHeight: math.max(
          0.0, constraints.maxHeight - 2 * _margin - safeArea.vertical),
    );
  }

  Offset _place(Rect lens, Size size, Size child) {
    final left = _margin + safeArea.left;
    final right = size.width - _margin - safeArea.right - child.width;
    final top = _margin + safeArea.top;
    final bottom = size.height - _margin - safeArea.bottom - child.height;
    final x = _TourLens._within(
        lens.center.dx - child.width / 2, left, math.max(left, right));

    final double y;
    if (lens.shortestSide < 2) {
      y = (size.height - child.height) / 2;
    } else if (lens.bottom + _gap <= bottom) {
      y = lens.bottom + _gap;
    } else {
      y = lens.top - _gap - child.height;
    }
    return Offset(x, _TourLens._within(y, top, math.max(top, bottom)));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset.lerp(
        _place(from, size, childSize),
        _place(to, size, childSize),
        travel.value,
      )!;

  @override
  bool shouldRelayout(_CardLayout oldDelegate) =>
      oldDelegate.from != from ||
      oldDelegate.to != to ||
      oldDelegate.safeArea != safeArea;
}

class _TourCard extends StatelessWidget {
  final InterfaceTourStep step;
  final int index;
  final int count;
  final bool isLast;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  const _TourCard({
    required this.step,
    required this.index,
    required this.count,
    required this.isLast,
    required this.onNext,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: const BorderRadius.all(Radius.circular(20)),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Le texte seul se fond d'une étape à l'autre : les boutons restent
          // les mêmes widgets, donc le focus de la télécommande ne bouge pas.
          AnimatedSwitcher(
            duration: AppMotion.fade(context, AppMotion.micro),
            switchInCurve: AppMotion.curve,
            switchOutCurve: AppMotion.curve,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topLeft,
              children: [...previous, if (current != null) current],
            ),
            child: Semantics(
              key: ValueKey(index),
              liveRegion: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Étape {0} sur {1}', [index + 1, count]),
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: AppType.caption,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    step.title,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: AppType.headline,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    step.body,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: AppType.body,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (!isLast) _TourButton(label: tr('Passer'), onTap: onSkip),
              const Spacer(),
              _TourButton(
                label: isLast ? tr('Terminer') : tr('Suivant'),
                primary: true,
                autofocus: true,
                onTap: onNext,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Les deux boutons de la carte, aux règles de `PROJECT_DESIGN.md` §8 : un
/// plein blanc pour continuer, un filet pour passer.
class _TourButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool primary;
  final bool autofocus;

  const _TourButton({
    required this.label,
    required this.onTap,
    this.primary = false,
    this.autofocus = false,
  });

  @override
  State<_TourButton> createState() => _TourButtonState();
}

class _TourButtonState extends State<_TourButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final primary = widget.primary;
    // Comme les onglets de l'en-tête : le voile de focus de Material ne se lit
    // pas depuis un canapé, donc l'anneau de l'app sur un téléviseur.
    final ringed = _focused && TvScope.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(
        color: ringed
            ? AppColors.accent
            : Colors.white.withValues(alpha: primary ? 0 : 0.12),
        width: ringed ? 2 : 1,
      ),
    );

    return Material(
      color: primary
          ? AppColors.textPrimary.withValues(alpha: 0.92)
          : Colors.transparent,
      shape: shape,
      child: InkWell(
        autofocus: widget.autofocus,
        customBorder: shape,
        onTap: widget.onTap,
        onFocusChange: (focused) {
          if (_focused != focused) setState(() => _focused = focused);
        },
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: AppLayout.minTouchTarget(context),
            minWidth: 88,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Center(
              widthFactor: 1,
              child: Text(
                widget.label,
                style: TextStyle(
                  color:
                      primary ? AppColors.background : AppColors.textSecondary,
                  fontSize: AppType.subhead,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
