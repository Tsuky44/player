import 'package:flutter/widgets.dart';

import '../../theme/app_motion.dart';

/// L'arrivée en cascade d'une grille ou d'une liste, à la manière d'OnyxHub
/// (`onyx-stagger`) : chaque carte monte de quelques pixels en apparaissant,
/// [AppMotion.stagger] après la précédente.
///
/// Pensée pour tenir sur une petite TV :
///
/// * **une seule horloge** pour toute la grille, posée ici, au lieu d'un
///   contrôleur par carte ;
/// * **seules les [maxAnimated] premières cartes** jouent, celles du premier
///   écran. Les pages ajoutées au défilement arrivent telles quelles ;
/// * **ni échelle ni flou** : une échelle rééchantillonnerait chaque affiche à
///   chaque image. Un fondu et une translation se composent sans repeindre la
///   carte, et une opacité pleine ne coûte plus de calque une fois arrivée ;
/// * **rien du tout en mode léger** ou sous « réduire les animations ».
///   OnyxHub garde un fondu ; ici la cascade entière saute, parce que vingt
///   calques d'opacité ouverts ensemble sont ce qu'une Apple TV HD ne tient
///   pas (ADR-0086).
class StaggeredEntranceScope extends StatefulWidget {
  /// Change quand la grille montre un nouvel ensemble (onglet, recherche,
  /// filtre) : la cascade rejoue. Un ajout de page ne le change pas.
  final Object? playKey;

  /// Combien de cartes, depuis la première, entrent en cascade.
  final int maxAnimated;

  final Widget child;

  const StaggeredEntranceScope({
    super.key,
    required this.playKey,
    required this.child,
    this.maxAnimated = 16,
  });

  /// Durée totale de la cascade de [count] cartes.
  static Duration totalFor(int count) =>
      AppMotion.emphasis + AppMotion.stagger * (count < 1 ? 0 : count - 1);

  @override
  State<StaggeredEntranceScope> createState() => _StaggeredEntranceScopeState();
}

class _StaggeredEntranceScopeState extends State<StaggeredEntranceScope>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: StaggeredEntranceScope.totalFor(widget.maxAnimated),
  );
  bool _played = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_played) {
      _played = true;
      _play();
    } else if (AppMotion.reduced(context) && _clock.isAnimating) {
      _clock.value = 1;
    }
  }

  @override
  void didUpdateWidget(StaggeredEntranceScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playKey != widget.playKey) _play();
  }

  void _play() {
    if (AppMotion.reduced(context)) {
      _clock.value = 1;
    } else {
      _clock.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _StaggerClock(
        clock: _clock,
        maxAnimated: widget.maxAnimated,
        child: widget.child,
      );
}

class _StaggerClock extends InheritedWidget {
  final AnimationController clock;
  final int maxAnimated;

  const _StaggerClock({
    required this.clock,
    required this.maxAnimated,
    required super.child,
  });

  @override
  bool updateShouldNotify(_StaggerClock oldWidget) =>
      oldWidget.clock != clock || oldWidget.maxAnimated != maxAnimated;
}

/// Une carte de la cascade, à la place [index] de la grille. Hors d'un
/// [StaggeredEntranceScope], ou au-delà de ses premières cartes, elle rend
/// [child] tel quel.
class StaggeredEntrance extends StatelessWidget {
  final int index;
  final Widget child;

  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.child,
  });

  /// La hauteur de la montée, celle d'OnyxHub.
  static const double rise = 18;

  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_StaggerClock>();
    if (scope == null || index >= scope.maxAnimated) return child;

    final total =
        StaggeredEntranceScope.totalFor(scope.maxAnimated).inMicroseconds;
    final start = (AppMotion.stagger * index).inMicroseconds / total;
    final end = start + AppMotion.emphasis.inMicroseconds / total;
    final interval =
        Interval(start, end.clamp(0.0, 1.0), curve: AppMotion.curve);

    // La structure reste la même avant, pendant et après la cascade : changer
    // d'arbre au dernier tick remonterait la carte et rechargerait son image.
    return AnimatedBuilder(
      animation: scope.clock,
      child: child,
      builder: (context, child) {
        final t = interval.transform(scope.clock.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, rise * (1 - t)),
            child: child,
          ),
        );
      },
    );
  }
}
