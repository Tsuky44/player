import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import 'app_network_image.dart';
import 'poster_card.dart';

/// D'où part une ouverture : la carte touchée, en coordonnées écran.
class LaunchOrigin {
  final Rect rect;

  /// L'affiche de la carte, même URL que celle qu'elle montre : l'image qui
  /// part vers l'écran sort du cache dès la première frame.
  final String? imageUrl;

  const LaunchOrigin({required this.rect, this.imageUrl});

  /// Mesure le widget porté par [key]. Null s'il n'est pas (ou plus) à l'écran.
  static LaunchOrigin? fromKey(GlobalKey key, {String? imageUrl}) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    return LaunchOrigin(rect: topLeft & box.size, imageUrl: imageUrl);
  }
}

/// Où mène l'ouverture, et donc quelle mise en scène.
enum LaunchDestination {
  /// Zoom : l'affiche quitte sa carte et grandit jusqu'au plein écran en se
  /// fondant dans le noir ; le lecteur — noir lui aussi tant que sa première
  /// image n'est pas là — prend le relais une fois l'écran couvert.
  player,

  /// Ouverture circulaire depuis la carte touchée, qui dévoile la fiche.
  details,
}

/// Ouvre [builder] avec la transition de [destination], partie de [origin].
///
/// Sans origine mesurable (carte sortie de l'écran…) ou quand le système
/// demande moins d'animations, retombe sur une [MaterialPageRoute] ordinaire.
Future<T?> pushPosterLaunch<T>(
  NavigatorState navigator, {
  required WidgetBuilder builder,
  required LaunchOrigin? origin,
  required LaunchDestination destination,
  RouteSettings? settings,
}) {
  final reduceMotion =
      MediaQuery.maybeDisableAnimationsOf(navigator.context) ?? false;
  final navBox = navigator.context.findRenderObject();

  if (origin == null || reduceMotion || navBox is! RenderBox) {
    return navigator.push<T>(
      MaterialPageRoute(settings: settings, builder: builder),
    );
  }

  // Le navigateur imbriqué ne couvre pas forcément tout l'écran (barre
  // latérale du shell) : l'origine est ramenée dans son repère à lui.
  final topLeft = navBox.globalToLocal(origin.rect.topLeft);

  return navigator.push<T>(
    PosterLaunchRoute<T>(
      builder: builder,
      originRect: topLeft & origin.rect.size,
      imageUrl: origin.imageUrl,
      destination: destination,
      settings: settings,
    ),
  );
}

class PosterLaunchRoute<T> extends PageRoute<T> {
  final WidgetBuilder builder;
  final Rect originRect;
  final String? imageUrl;
  final LaunchDestination destination;

  PosterLaunchRoute({
    required this.builder,
    required this.originRect,
    required this.destination,
    this.imageUrl,
    super.settings,
  });

  @override
  Duration get transitionDuration => destination == LaunchDestination.player
      ? const Duration(milliseconds: 520)
      : const Duration(milliseconds: 560);

  // Le retour rejoue la même scène à l'envers, en plus vif : le panneau se
  // resserre vers la carte, le cercle aussi.
  @override
  Duration get reverseTransitionDuration =>
      destination == LaunchDestination.player
          ? const Duration(milliseconds: 360)
          : const Duration(milliseconds: 420);

  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation) =>
      builder(context);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, page) => destination == LaunchDestination.player
          ? _ZoomFrame(
              progress: animation.value,
              reversing: animation.status == AnimationStatus.reverse,
              originRect: originRect,
              imageUrl: imageUrl,
              page: page!,
            )
          : _IrisFrame(
              progress: animation.value,
              originRect: originRect,
              page: page!,
            ),
    );
  }
}

double _interval(double t, double begin, double end, Curve curve) =>
    curve.transform(((t - begin) / (end - begin)).clamp(0.0, 1.0));

/// Pose la page toujours au même endroit de l'arbre, quelle que soit la phase :
/// la déplacer ferait remonter l'écran de destination — et relancer le lecteur
/// — au moment où l'animation se termine.
Widget _stage({
  required Widget page,
  required double pageOpacity,
  CustomClipper<Path>? pageClip,
  required List<Widget> under,
  required List<Widget> over,
}) {
  return Stack(
    children: [
      Positioned.fill(child: IgnorePointer(child: Stack(children: under))),
      Positioned.fill(
        key: const ValueKey('launch-page'),
        child: Opacity(
          opacity: pageOpacity,
          child: ClipPath(
            clipper: pageClip,
            clipBehavior: pageClip == null ? Clip.none : Clip.antiAlias,
            // The clip and the opacity change every frame of the transition;
            // the page under them does not. Without its own layer the whole
            // detail page — backdrop, rows of artwork — was repainted 60 times
            // a second for the length of the opening.
            child: RepaintBoundary(child: page),
          ),
        ),
      ),
      Positioned.fill(child: IgnorePointer(child: Stack(children: over))),
    ],
  );
}

/// Le lancement du lecteur : l'écran vient à soi depuis la carte touchée.
///
/// Rien n'est appliqué au lecteur lui-même. Sur Android sa vidéo est une
/// `SurfaceView`, que Flutter ne sait ni découper ni mettre à l'échelle : c'est
/// un panneau noir qui grandit, et le lecteur — noir aussi jusqu'à sa première
/// image — n'apparaît qu'une fois l'écran entièrement couvert.
class _ZoomFrame extends StatelessWidget {
  final double progress;
  final bool reversing;
  final Rect originRect;
  final String? imageUrl;
  final Widget page;

  const _ZoomFrame({
    required this.progress,
    required this.reversing,
    required this.originRect,
    required this.imageUrl,
    required this.page,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final full = Offset.zero & constraints.biggest;
        final t = progress;

        final grow = reversing
            ? Curves.easeInCubic.transform(t)
            : Curves.easeInOutCubic.transform(t);
        final rect = Rect.lerp(originRect, full, grow)!;
        final radius = PosterCard.radius * (1 - grow);
        final done = !reversing && t >= 1.0;
        final artwork = reversing
            ? _interval(t, 0.0, 0.45, Curves.easeIn)
            : 1 - _interval(t, 0.12, 0.55, Curves.easeInOut);

        // Au retour, le panneau s'efface en arrivant sur la carte plutôt que
        // de s'y poser : la carte a pu bouger entre-temps.
        final fade = reversing ? _interval(t, 0.0, 0.35, Curves.easeOut) : 1.0;

        return _stage(
          page: page,
          pageOpacity: done ? 1 : 0,
          under: [
            if (!done) ...[
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(
                    alpha: 0.6 * _interval(t, 0, 0.7, Curves.easeOut),
                  ),
                ),
              ),
              Positioned.fromRect(
                rect: rect,
                child: Opacity(
                  opacity: fade,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(radius),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: 0.5 * (1 - grow),
                          ),
                          blurRadius: 40,
                          offset: const Offset(0, 18),
                        ),
                      ],
                    ),
                    // L'affiche se fond dans le noir pendant la montée : elle
                    // a disparu avant d'être assez grande pour paraître floue
                    // ou mal cadrée.
                    child: artwork > 0.001
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(radius),
                            child: Opacity(
                              opacity: artwork,
                              child: AppNetworkImage(
                                url: imageUrl,
                                fit: BoxFit.cover,
                                decodeWidth: originRect.width,
                                fadeInDuration: Duration.zero,
                                placeholder: const SizedBox.shrink(),
                                errorWidget: const SizedBox.shrink(),
                              ),
                            ),
                          )
                        : null,
                  ),
                ),
              ),
            ],
          ],
          over: const [],
        );
      },
    );
  }
}

class _IrisFrame extends StatelessWidget {
  final double progress;
  final Rect originRect;
  final Widget page;

  const _IrisFrame({
    required this.progress,
    required this.originRect,
    required this.page,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final t = progress;

        final centre = originRect.center;
        // Le cercle final doit atteindre le coin le plus éloigné de la carte.
        final farthest = [
          Offset.zero,
          Offset(size.width, 0),
          Offset(0, size.height),
          Offset(size.width, size.height),
        ].map((c) => (c - centre).distance).reduce(math.max);
        final startRadius = originRect.shortestSide / 2;

        final open = _interval(t, 0.0, 0.9, Curves.easeInOutCubicEmphasized);
        final radius = startRadius + (farthest - startRadius) * open;

        // La page n'apparaît qu'une fois le cercle assez grand pour qu'on n'en
        // voie pas un fragment découpé ; avant, c'est le fond de l'app qui
        // s'ouvre depuis la carte.
        final reveal = _interval(t, 0.18, 0.7, Curves.easeOutCubic);
        final dim = _interval(t, 0.0, 0.6, Curves.easeOut);
        final done = t >= 1.0;

        return _stage(
          page: page,
          pageOpacity: reveal,
          pageClip: done ? null : _CircleClipper(centre, radius),
          under: [
            if (!done) ...[
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.5 * dim),
                ),
              ),
              Positioned.fromRect(
                rect: Rect.fromCircle(center: centre, radius: radius),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.background,
                    // Un halo d'accent borde le cercle pendant qu'il s'ouvre,
                    // et s'efface en arrivant.
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.accent.withValues(
                          alpha: 0.35 * (1 - open),
                        ),
                        blurRadius: 40,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
          over: const [],
        );
      },
    );
  }
}

class _CircleClipper extends CustomClipper<Path> {
  final Offset centre;
  final double radius;

  _CircleClipper(this.centre, this.radius);

  @override
  Path getClip(Size size) =>
      Path()..addOval(Rect.fromCircle(center: centre, radius: radius));

  @override
  bool shouldReclip(_CircleClipper old) =>
      old.centre != centre || old.radius != radius;
}
