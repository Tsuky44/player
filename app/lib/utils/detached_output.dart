import 'dart:async';

/// Ce que l'app écrit avec `print` quand elle n'a nulle part où l'écrire.
///
/// Lancée depuis le menu Démarrer, l'app Windows n'a ni console ni sortie
/// redirigée. Le moteur Flutter y recopie pourtant chaque `print` de Dart, et
/// le 24/09/2026 il a fini par tomber dessus : arrêt immédiat (`0xc0000409`
/// dans `flutter_windows.dll`) au lancement de chaque média, quand la trace de
/// démarrage de mpv écrit ses lignes. La même app, sortie redirigée vers un
/// fichier, lisait sans broncher.
///
/// Le runner (`windows/runner/main.cpp`) passe alors [flag] à l'app, qui fait
/// taire `print` pour tout ce qui tourne sous elle. `ClientLog` garde ses
/// lignes : il les enregistre avant de les transmettre à `print`.
abstract final class DetachedOutput {
  /// Doit rester identique à `kNoStdoutFlag` dans `windows/runner/main.cpp`.
  static const flag = '--no-stdout';

  /// Lance [body], `print` coupé si le runner a signalé l'absence de sortie.
  static void run(List<String> args, Future<void> Function() body) {
    if (!args.contains(flag)) {
      body();
      return;
    }
    runZoned(
      body,
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {},
      ),
    );
  }
}
