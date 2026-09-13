import 'package:flutter/material.dart';

import '../navigation/search_route_observer.dart';

/// L'interface d'un téléviseur, dessinée plus petite.
///
/// Un téléviseur annonce le plus souvent 960 × 540 pixels logiques — la
/// densité d'un téléphone posée sur un écran de salon. L'app se mettait donc en
/// page comme sur une tablette étroite : bandeau sur les deux tiers de l'écran,
/// cinq affiches par rangée, textes énormes vus du canapé. Jellyfin et les
/// autres apps TV montrent bien plus de contenu à la fois.
///
/// On met donc la page en page sur [designWidth] pixels logiques, puis on la
/// réduit pour qu'elle remplisse l'écran. Tout suit — marges, affiches, textes,
/// anneaux de focus — sans qu'aucun écran n'ait à connaître le téléviseur. Un
/// écran qui annonce déjà au moins cette largeur n'est pas touché.
class TvUiScale extends StatelessWidget {
  const TvUiScale({super.key, required this.child});

  /// La largeur logique sur laquelle la page est mise en page.
  static const double designWidth = 1280;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (!size.isFinite || size.width <= 0 || size.width >= designWidth) {
          return child;
        }
        final scale = size.width / designWidth;
        final laidOut = size / scale;
        final media = MediaQuery.of(context);

        return MediaQuery(
          data: media.copyWith(
            size: laidOut,
            devicePixelRatio: media.devicePixelRatio * scale,
            padding: media.padding / scale,
            viewPadding: media.viewPadding / scale,
            viewInsets: media.viewInsets / scale,
            systemGestureInsets: media.systemGestureInsets / scale,
          ),
          // FittedBox plutôt qu'un Transform à la main : il réduit le dessin
          // *et* les coordonnées des touches, et la page garde exactement la
          // taille de l'écran.
          child: FittedBox(
            fit: BoxFit.fill,
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(size: laidOut, child: child),
          ),
        );
      },
    );
  }
}

/// Applique [TvUiScale] à chaque page de l'app, sauf au lecteur.
///
/// Par la transition de page plutôt qu'autour du navigateur entier : la vidéo
/// d'ExoPlayer est une SurfaceView, une couche du système que Flutter ne sait
/// pas réduire — la page se serait réduite autour d'un trou resté pleine
/// taille. Le lecteur a d'ailleurs ses propres tailles pour la télévision.
class TvScaledPageTransitionsBuilder extends PageTransitionsBuilder {
  const TvScaledPageTransitionsBuilder();

  static const PageTransitionsTheme _defaults = PageTransitionsTheme();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final isPlayer = route.settings.name == SearchRouteObserver.playerRouteName;
    return _defaults.buildTransitions<T>(
      route,
      context,
      animation,
      secondaryAnimation,
      isPlayer ? child : TvUiScale(child: child),
    );
  }
}
