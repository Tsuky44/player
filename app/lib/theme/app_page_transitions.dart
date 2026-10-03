import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../navigation/search_route_observer.dart';
import 'app_motion.dart';

/// La transition de page d'Onyx : la page arrive en fondu en montant de
/// quelques pixels, et repart de même.
///
/// Sans elle, chaque `MaterialPageRoute` prenait celle de son système : un
/// zoom sous Windows et Android, un glissé latéral sous macOS — la même fiche
/// ne s'ouvrait pas de la même façon selon l'ordinateur, et le zoom d'Android
/// (450 ms) sortait du contrat de mouvement (`PROJECT_DESIGN.md` §10,
/// 180–280 ms).
///
/// iOS garde le glissé de [CupertinoPageTransitionsBuilder] : il porte le geste
/// de retour depuis le bord de l'écran, que tout utilisateur d'iPhone fait
/// sans y penser.
class OnyxPageTransitionsBuilder extends PageTransitionsBuilder {
  const OnyxPageTransitionsBuilder();

  /// La montée, en fraction de la hauteur : une vingtaine de pixels sur un
  /// téléphone, assez pour donner une direction, trop peu pour « glisser ».
  static const double rise = 0.025;

  @override
  Duration get transitionDuration => AppMotion.emphasis;

  /// Le retour est plus vif que l'aller : on quitte une page qu'on connaît.
  @override
  Duration get reverseTransitionDuration => AppMotion.standard;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: AppMotion.curve,
      reverseCurve: AppMotion.curve.flipped,
    );
    final faded = FadeTransition(opacity: curved, child: child);
    // Le lecteur ne subit jamais de transformation : sa vidéo est une surface
    // native sur Android, que Flutter ne sait pas déplacer. Un fondu seul. Et
    // sous « réduire les animations », le fondu reste, la montée disparaît
    // ([AppMotion.move]).
    if (route.settings.name == SearchRouteObserver.playerRouteName ||
        AppMotion.reduced(context)) {
      return faded;
    }
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, rise),
        end: Offset.zero,
      ).animate(curved),
      child: faded,
    );
  }
}

/// Le thème des transitions de l'app, par plateforme.
const PageTransitionsTheme appPageTransitionsTheme = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: OnyxPageTransitionsBuilder(),
    TargetPlatform.fuchsia: OnyxPageTransitionsBuilder(),
    TargetPlatform.linux: OnyxPageTransitionsBuilder(),
    TargetPlatform.macOS: OnyxPageTransitionsBuilder(),
    TargetPlatform.windows: OnyxPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
  },
);
