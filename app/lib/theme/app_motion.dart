import 'package:flutter/material.dart';

import 'lite_mode.dart';

/// Motion tokens — the single place that decides how long anything in the app
/// takes to move, and how it behaves when the user asked the system for less
/// motion.
///
/// **Durations stay inside 180–280 ms.** That range is the contract
/// (`PROJECT_DESIGN.md` §10: "Motion: 180–280ms ease-out"), not a preference.
/// Adding a value outside it here means the contract changed first.
///
/// **There is no spring in this file, on purpose.** A spring only earns its
/// place where a gesture carries a velocity worth handing off — a drag release,
/// a flick. Nothing in the app does that yet, and Flutter's implicit animations
/// already retarget from the value currently on screen, which is what makes an
/// animation interruptible. The first real candidate is the scrubber, if it
/// ever snaps to chapters on a flick. When that happens the parameters are
/// derived, not guessed: pick a damping ratio and a response (in seconds), then
/// `SpringDescription.withDampingRatio(mass: 1, stiffness: m * pow(2 * pi / response, 2), ratio: damping)`.
abstract final class AppMotion {
  /// Micro-states: hover, selection, a chip changing shape.
  static const Duration micro = Duration(milliseconds: 180);

  /// Le zoom du focus télécommande. Sous la plage 180–280 ms parce qu'il suit
  /// la répétition des flèches : un focus qui finit de grossir après que le
  /// suivant est parti traîne derrière la télécommande.
  static const Duration focus = Duration(milliseconds: 160);

  /// The default. Chrome fades, appearances, disappearances.
  static const Duration standard = Duration(milliseconds: 200);

  /// Large surfaces — sheets, panels — which read as slower at the same speed.
  static const Duration emphasis = Duration(milliseconds: 260);

  /// Un défilement qui suit une entrée continue — flèche maintenue, élan du
  /// trackpad de l'Apple TV. Hors de la plage 180–280 ms parce que ce n'est
  /// pas une transition : chaque pas relance le défilement, qui doit avoir
  /// fini avant le suivant (`TvKeyRepeat.repeatInterval`, 110 ms), sans quoi
  /// le focus court devant une rangée pas encore construite.
  static const Duration track = Duration(milliseconds: 90);

  /// Une dérive lente qui anime une image fixe — le zoom de l'aperçu au survol
  /// d'une carte « Reprendre ». Hors de la plage 180–280 ms parce que ce n'est
  /// pas une transition : rien n'attend qu'elle finisse, elle donne seulement
  /// de la vie à une suite d'images. Toujours passée par [move], donc nulle
  /// sous « réduire les animations ».
  static const Duration ambient = Duration(milliseconds: 2600);

  /// L'écart entre deux cartes d'une arrivée en cascade
  /// (`StaggeredEntranceScope`). Un décalage de départ, pas une durée :
  /// chaque carte dure [emphasis]. 35 ms, comme la cascade d'OnyxHub : assez
  /// pour lire l'ordre, trop peu pour qu'on attende la dernière.
  static const Duration stagger = Duration(milliseconds: 35);

  /// Le faisceau qui traverse une fois un badge « Disponible ». Hors de la
  /// plage 180–280 ms parce que ce n'est pas une transition : rien n'attend
  /// qu'il finisse, il signale seulement l'état en passant. Toujours passé par
  /// [move], donc absent sous « réduire les animations » et en mode léger.
  static const Duration sweep = Duration(milliseconds: 900);

  /// The app's only curve (`PROJECT_DESIGN.md` §10: "ease-out").
  static const Curve curve = Curves.easeOut;

  /// Press-down scale for interactive cards. Deliberately restrained:
  /// `PROJECT_DESIGN.md` §4 lists the incumbent brief's aggressive 1.1
  /// scale-on-focus as non-transferable.
  static const double pressScale = 0.97;

  /// Whether the platform asked for reduced motion — "Reduce Motion" on
  /// macOS/iOS, "Remove animations" on Android.
  ///
  /// Le mode léger (ADR-0086) pose la même question : un mouvement
  /// géométrique redessine tout ce qu'il traverse à chaque image, et c'est ce
  /// qu'une Apple TV HD ne tient pas. Les fondus restent, comme sous
  /// « réduire les animations ».
  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) || LiteScope.of(context);

  /// Duration for an opacity or colour animation.
  ///
  /// Survives reduced motion by design: a cross-fade is not vestibular, and
  /// removing it makes the interface harder to follow rather than calmer.
  /// Takes the context it does not read so that every call site asks the same
  /// question — `fade` or `move` — instead of having to remember which of the
  /// two cares about the setting.
  static Duration fade(BuildContext context, [Duration duration = standard]) =>
      duration;

  /// Duration for a position, size or scale animation — anything geometric.
  ///
  /// Collapses to zero under reduced motion, so the widget lands on its target
  /// state directly instead of travelling there.
  static Duration move(BuildContext context, [Duration duration = standard]) =>
      reduced(context) ? Duration.zero : duration;
}
