import 'dart:async';
import 'dart:ui' show FrameTiming, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Dit si l'interface tient sa cadence, à partir du temps de chaque image.
///
/// La mémoire ne suffit pas à reconnaître un appareil trop faible : un
/// Raspberry Pi 4 a 4 Go et un processeur graphique d'entrée de gamme, un
/// vieux portable sous Windows a de la mémoire et une puce intégrée datée. Ce
/// qui ne trompe pas, c'est le temps qu'une image met à se construire et à se
/// dessiner. Flutter ne produit d'images que quand quelque chose bouge, donc
/// chaque image mesurée est une animation ou un défilement, exactement ce que
/// le mode léger allège.
///
/// Une image est lente quand sa construction ou son dessin dépasse le budget
/// d'une image (16,7 ms à 60 Hz). Le verdict tombe sur une fenêtre de
/// [window] images, quand au moins [slowShare] d'entre elles sont lentes :
/// une saccade isolée (une affiche décodée, un shader compilé) n'y suffit pas.
class FrameBudgetWatch {
  FrameBudgetWatch({
    required this.frameBudget,
    this.window = 180,
    this.slowShare = 0.3,
  });

  final Duration frameBudget;
  final int window;
  final double slowShare;

  int _frames = 0;
  int _slow = 0;

  /// Ajoute une image ; vrai quand la fenêtre qu'elle ferme est lente. La
  /// fenêtre repart de zéro dans les deux cas.
  bool add({required Duration build, required Duration raster}) {
    _frames++;
    if (build > frameBudget || raster > frameBudget) _slow++;
    if (_frames < window) return false;
    final slow = _slow >= window * slowShare;
    _frames = 0;
    _slow = 0;
    return slow;
  }

  /// Le délai avant la première mesure : les premières secondes compilent
  /// leurs shaders et décodent toutes leurs affiches d'un coup, ce qui saccade
  /// sur n'importe quel appareil.
  static const Duration warmUp = Duration(seconds: 10);

  /// Surveille les images de [binding] et appelle [onSustainedJank] à la
  /// première fenêtre lente. Rend de quoi arrêter.
  static VoidCallback install(
    SchedulerBinding binding, {
    required VoidCallback onSustainedJank,
  }) {
    final refresh =
        PlatformDispatcher.instance.displays.firstOrNull?.refreshRate ?? 60;
    final watch = FrameBudgetWatch(
      frameBudget: Duration(
        microseconds: (1e6 / (refresh >= 30 ? refresh : 60)).round(),
      ),
    );
    var stopped = false;
    void onTimings(List<FrameTiming> timings) {
      if (stopped) return;
      for (final timing in timings) {
        if (watch.add(
            build: timing.buildDuration, raster: timing.rasterDuration)) {
          onSustainedJank();
          return;
        }
      }
    }

    final start = Timer(warmUp, () {
      if (!stopped) binding.addTimingsCallback(onTimings);
    });
    return () {
      stopped = true;
      start.cancel();
      binding.removeTimingsCallback(onTimings);
    };
  }
}
