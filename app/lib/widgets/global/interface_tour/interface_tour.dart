import 'package:flutter/material.dart';

import '../../../l10n/tr.dart';
import '../../../tv/tv_mode.dart';
import '../../../tv/tv_ui_scale.dart';
import 'interface_tour_overlay.dart';
import 'tour_anchor.dart';

/// Une étape de la présentation : une zone à montrer, et ce qu'on en dit.
class InterfaceTourStep {
  /// `null` pour une étape qui ne montre rien — le mot d'accueil.
  final TourAnchor? anchor;
  final String title;
  final String body;

  const InterfaceTourStep({
    this.anchor,
    required this.title,
    required this.body,
  });
}

/// Les étapes de la présentation, dans l'ordre.
///
/// Toutes y sont : celles dont la zone n'existe pas pour ce compte ou sur cet
/// appareil sont écartées par [showInterfaceTour], qui regarde l'écran plutôt
/// que de refaire ici le calcul des droits.
List<InterfaceTourStep> interfaceTourSteps() => [
      InterfaceTourStep(
        title: tr('Bienvenue sur Onyx'),
        body: tr('Quelques repères pour vous y retrouver. '
            'Cela prend moins d’une minute.'),
      ),
      InterfaceTourStep(
        anchor: TourAnchor.hero,
        title: tr('À la une'),
        body: tr('Le bandeau met un titre en avant. '
            'Lancez-le d’ici, ou ouvrez sa fiche.'),
      ),
      InterfaceTourStep(
        anchor: TourAnchor.resume,
        title: tr('Reprendre la lecture'),
        body: tr('Vos lectures en cours vous attendent ici. '
            'Un appui, et le film reprend où vous l’aviez laissé.'),
      ),
      InterfaceTourStep(
        anchor: TourAnchor.recent,
        title: tr('Les nouveautés'),
        body: tr('Les derniers ajouts s’affichent ici. Ce que vous commencez '
            'apparaîtra juste au-dessus, prêt à être repris.'),
      ),
      InterfaceTourStep(
        anchor: TourAnchor.library,
        title: tr('Votre médiathèque'),
        body: tr('L’accueil reprend là où vous vous êtes arrêté. '
            'Films et Séries ouvrent tout le catalogue.'),
      ),
      InterfaceTourStep(
        anchor: TourAnchor.requests,
        title: tr('Demandes'),
        body: tr('Un titre manque ? Demandez-le ici et suivez son arrivée.'),
      ),
      InterfaceTourStep(
        anchor: TourAnchor.downloads,
        title: tr('Hors ligne'),
        body: tr('Vos téléchargements vous attendent ici, '
            'prêts à être regardés sans connexion.'),
      ),
      InterfaceTourStep(
        anchor: TourAnchor.search,
        title: tr('Recherche'),
        body: tr('Retrouvez un film ou une série par son titre.'),
      ),
      InterfaceTourStep(
        anchor: TourAnchor.account,
        title: tr('Votre compte'),
        body: tr('Paramètres, serveurs et séances à plusieurs '
            'se trouvent dans ce menu.'),
      ),
    ];

/// La demande de rejouer la présentation, faite depuis les réglages.
///
/// Un signal global parce que les réglages et la coquille ne se voient pas :
/// la page des réglages est une route posée par-dessus, pas un enfant de la
/// coquille qui sait où sont les zones à montrer.
abstract final class InterfaceTourReplay {
  static final ValueNotifier<int> _requests = ValueNotifier<int>(0);

  /// Prévient à chaque demande.
  static Listenable get requests => _requests;

  static void request() => _requests.value++;
}

/// Joue la présentation de l'interface par-dessus l'écran, et rend la main
/// quand elle est finie ou passée.
///
/// Une route du navigateur racine : le focus y est enfermé, et Retour — la
/// télécommande, le geste d'Android, Échap — la ferme comme n'importe quelle
/// page, ce qui vaut « Passer ».
Future<void> showInterfaceTour(
  BuildContext context, {
  required TourAnchors anchors,
  List<InterfaceTourStep>? steps,
}) {
  final shown = [
    for (final step in steps ?? interfaceTourSteps())
      if (step.anchor == null || anchors.rectOf(step.anchor!) != null) step,
  ];
  if (shown.isEmpty) return Future<void>.value();

  final isTv = TvScope.of(context);
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierLabel: tr('Présentation de l’interface'),
      // Pas de fondu de route : un flou sous une opacité ne se peint pas, et
      // le voile arriverait d'un coup à la fin. L'overlay anime lui-même son
      // entrée et sa sortie.
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (routeContext, _, __) {
        final overlay = InterfaceTourOverlay(
          steps: shown,
          anchors: anchors,
          onClose: () => Navigator.of(routeContext).maybePop(),
        );
        // Les pages d'un téléviseur passent par cette mise à l'échelle dans
        // leur transition ; cette route n'en a pas, donc elle la pose
        // elle-même pour parler à la même taille que l'écran qu'elle décrit.
        return isTv ? TvUiScale(child: overlay) : overlay;
      },
    ),
  );
}
