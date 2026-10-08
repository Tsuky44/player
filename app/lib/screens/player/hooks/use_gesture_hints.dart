import 'dart:async';

import 'package:flutter/widgets.dart';

/// Les deux indications brèves qui répondent à un geste sur l'image : la
/// recherche d'un double tap (« −30 s ») et le cadrage d'un pincement.
///
/// Chacune apparaît, s'efface, puis quitte l'arbre une fois effacée : son
/// flou ou son animation ne se paient pas pendant le reste du film.
class GestureHints extends ChangeNotifier {
  BoxFit zoomFit = BoxFit.contain;
  bool zoomVisible = false;
  bool zoomMounted = false;
  Timer? _zoomTimer;

  /// Running total of a burst of double-tap seeks, in seconds. Reset once the
  /// taps stop, or the moment one goes the other way.
  int seekSeconds = 0;
  bool seekForward = true;

  /// Bumped per tap so the overlay can replay its arc; see
  /// [SeekFeedbackOverlay.pulse].
  int seekPulse = 0;
  bool seekVisible = false;
  bool seekMounted = false;
  Timer? _seekTimer;

  bool _disposed = false;

  void showZoom(BoxFit fit) {
    _zoomTimer?.cancel();
    zoomFit = fit;
    zoomVisible = true;
    zoomMounted = true;
    notifyListeners();
    _zoomTimer = Timer(const Duration(milliseconds: 900), () {
      if (_disposed) return;
      zoomVisible = false;
      notifyListeners();
      // Taken out of the tree only once it has finished fading, so the blur
      // layer is not paid for over the rest of the film.
      _zoomTimer = Timer(const Duration(milliseconds: 300), () {
        if (_disposed) return;
        zoomMounted = false;
        notifyListeners();
      });
    });
  }

  void showSeek(int seconds) {
    final forward = seconds > 0;
    _seekTimer?.cancel();
    // A burst only accumulates while it keeps going the same way. Tapping
    // back after tapping forward starts a new count, because "30 s" would
    // otherwise be describing a journey that ended 10 s from where it began.
    seekSeconds = (seekVisible && forward == seekForward)
        ? seekSeconds + seconds.abs()
        : seconds.abs();
    seekForward = forward;
    seekPulse++;
    seekVisible = true;
    seekMounted = true;
    notifyListeners();
    _seekTimer = Timer(const Duration(milliseconds: 700), () {
      if (_disposed) return;
      seekVisible = false;
      notifyListeners();
      // Out of the tree once faded, so its ticker is not left running over the
      // rest of the film.
      _seekTimer = Timer(const Duration(milliseconds: 300), () {
        if (_disposed) return;
        seekMounted = false;
        notifyListeners();
      });
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _zoomTimer?.cancel();
    _seekTimer?.cancel();
    super.dispose();
  }
}
