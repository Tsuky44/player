import 'package:flutter/widgets.dart';

/// Les zones du chrome que la présentation de l'interface sait montrer.
enum TourAnchor {
  /// Les boutons du bandeau de l'accueil.
  hero,

  /// La rangée « Reprendre la lecture ».
  resume,

  /// La première rangée de nouveautés, pour un compte qui n'a encore rien à
  /// reprendre.
  recent,

  /// Accueil, Films et Séries, d'un seul tenant.
  library,
  requests,
  downloads,
  search,
  account,
}

/// Où se trouvent, à l'écran, les zones que la présentation montre.
///
/// Un registre plutôt que des `GlobalKey` : la même zone existe en plusieurs
/// exemplaires — le compte est dans l'en-tête du bureau, dans la barre de
/// l'accueil et dans celle des catalogues du téléphone — et une clé globale
/// montée deux fois fait tomber l'arbre. Chaque [TourTarget] s'inscrit ici, et
/// la présentation demande celle qui est posée à l'écran.
class TourAnchors {
  final Map<TourAnchor, List<BuildContext>> _targets = {};

  void _attach(TourAnchor anchor, BuildContext context) =>
      _targets.putIfAbsent(anchor, () => []).add(context);

  void _detach(TourAnchor anchor, BuildContext context) =>
      _targets[anchor]?.remove(context);

  /// Le rectangle de la zone, en coordonnées de la fenêtre, ou `null` quand
  /// cet écran ne la montre pas (pas le droit de demander, pas de
  /// téléchargements sur le web).
  ///
  /// À appeler hors de la construction et de la mise en page : la réponse lit
  /// la taille d'un autre objet de rendu.
  Rect? rectOf(TourAnchor anchor) => _find(anchor)?.$2;

  /// Fait défiler la page jusqu'à ce que la zone soit à l'écran. Sans effet
  /// pour une zone du chrome, qui ne défile pas, ou déjà visible.
  Future<void> reveal(
    TourAnchor anchor, {
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) async {
    // « Garder visible » des deux côtés plutôt qu'un alignement : une zone
    // déjà à l'écran ne doit pas faire bouger la page sous le voile.
    for (final policy in const [
      ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    ]) {
      final context = _find(anchor)?.$1;
      if (context == null) return;
      await Scrollable.ensureVisible(
        context,
        duration: duration,
        curve: curve,
        alignmentPolicy: policy,
      );
    }
  }

  (BuildContext, Rect)? _find(TourAnchor anchor) {
    final contexts = _targets[anchor];
    if (contexts == null) return null;
    (BuildContext, Rect)? fallback;
    // La dernière inscrite d'abord : c'est celle de l'écran venu se poser
    // par-dessus les autres.
    for (final context in contexts.reversed) {
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      if (box.size.isEmpty) continue;
      final rect = MatrixUtils.transformRect(
        box.getTransformTo(null),
        Offset.zero & box.size,
      );
      // Le bandeau de l'accueil construit ses diapositives voisines d'avance :
      // leurs boutons existent, à une largeur d'écran de là. Celle qui est
      // dans la fenêtre passe devant.
      final view = View.maybeOf(context);
      final width = view == null
          ? double.infinity
          : view.physicalSize.width / view.devicePixelRatio;
      if (rect.right > 0 && rect.left < width) return (context, rect);
      fallback ??= (context, rect);
    }
    return fallback;
  }
}

/// Met un [TourAnchors] à portée des [TourTarget] de l'écran.
class TourAnchorScope extends InheritedWidget {
  final TourAnchors anchors;

  const TourAnchorScope({
    super.key,
    required this.anchors,
    required super.child,
  });

  static TourAnchors? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TourAnchorScope>()?.anchors;

  @override
  bool updateShouldNotify(TourAnchorScope oldWidget) =>
      oldWidget.anchors != anchors;
}

/// Désigne [child] comme la zone [anchor] de la présentation.
///
/// Sans [TourAnchorScope] au-dessus — un écran monté seul, la coquille hors
/// ligne — le widget ne fait rien : il n'y a pas de présentation à servir.
class TourTarget extends StatefulWidget {
  final TourAnchor anchor;
  final Widget child;

  const TourTarget({super.key, required this.anchor, required this.child});

  @override
  State<TourTarget> createState() => _TourTargetState();
}

class _TourTargetState extends State<TourTarget> {
  TourAnchors? _anchors;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final anchors = TourAnchorScope.maybeOf(context);
    if (identical(anchors, _anchors)) return;
    _anchors?._detach(widget.anchor, context);
    _anchors = anchors?.._attach(widget.anchor, context);
  }

  @override
  void didUpdateWidget(TourTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.anchor == widget.anchor) return;
    _anchors
      ?.._detach(oldWidget.anchor, context)
      .._attach(widget.anchor, context);
  }

  @override
  void dispose() {
    _anchors?._detach(widget.anchor, context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
