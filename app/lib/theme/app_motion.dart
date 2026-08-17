import 'package:flutter/material.dart';

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

  /// The default. Chrome fades, appearances, disappearances.
  static const Duration standard = Duration(milliseconds: 200);

  /// Large surfaces — sheets, panels — which read as slower at the same speed.
  static const Duration emphasis = Duration(milliseconds: 260);

  /// The app's only curve (`PROJECT_DESIGN.md` §10: "ease-out").
  static const Curve curve = Curves.easeOut;

  /// Press-down scale for interactive cards. Deliberately restrained:
  /// `PROJECT_DESIGN.md` §4 lists the incumbent brief's aggressive 1.1
  /// scale-on-focus as non-transferable.
  static const double pressScale = 0.97;

  /// Whether the platform asked for reduced motion — "Reduce Motion" on
  /// macOS/iOS, "Remove animations" on Android.
  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

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
