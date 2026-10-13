import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// La fenêtre de l'app est visible : au premier plan, ou simplement sans le
/// focus (`inactive`, une autre fenêtre du Mac au-dessus d'une partie).
/// Réduite, cachée ou en arrière-plan, elle ne l'est plus.
///
/// Flutter cesse déjà de dessiner une fenêtre cachée, mais pas de faire
/// tourner les minuteries : un sondage réseau ou un carrousel qui avance
/// continuaient de réveiller l'app pour rien.
abstract final class AppForeground {
  static final ValueNotifier<bool> _visible = ValueNotifier<bool>(true);
  static AppLifecycleListener? _listener;

  static ValueListenable<bool> get visible {
    _listen();
    return _visible;
  }

  static bool get isVisible => visible.value;

  static void _listen() {
    if (_listener != null) return;
    final binding = WidgetsBinding.instance;
    final initial = binding.lifecycleState;
    if (initial != null) _visible.value = _isVisible(initial);
    _listener = AppLifecycleListener(
      binding: binding,
      onStateChange: (state) => _visible.value = _isVisible(state),
    );
  }

  static bool _isVisible(AppLifecycleState state) =>
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  @visibleForTesting
  static void debugSetVisible(bool visible) {
    _listen();
    _visible.value = visible;
  }
}

/// Pour un widget qui fait du travail de fond (minuterie, sondage) : il n'en
/// fait que tant qu'on le voit.
///
/// « Vu », c'est deux choses à la fois : sa page est au premier plan (ni un
/// onglet caché — voir `ShellTabStack` —, ni une page recouverte par une
/// autre, ni l'accueil sous le lecteur), et la fenêtre de l'app est visible
/// ([AppForeground]). Flutter coupe déjà les animations d'une page cachée par
/// [TickerMode] ; c'est ce même signal qui sert ici.
///
/// [didChangeOnScreen] est appelé à chaque passage, y compris la première
/// fois que le widget apparaît : c'est là qu'on démarre et qu'on arrête son
/// travail, plutôt que dans `initState`. Il ne doit pas appeler `setState`
/// directement — il peut être appelé pendant `didChangeDependencies`.
mixin OnScreenState<T extends StatefulWidget> on State<T> {
  ValueListenable<TickerModeData>? _tickerMode;
  bool _onScreen = false;

  /// Le widget est vu, en ce moment.
  bool get isOnScreen => _onScreen;

  void didChangeOnScreen(bool onScreen);

  @override
  void initState() {
    super.initState();
    AppForeground.visible.addListener(_update);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = TickerMode.getValuesNotifier(context);
    if (!identical(notifier, _tickerMode)) {
      _tickerMode?.removeListener(_update);
      _tickerMode = notifier..addListener(_update);
    }
    _update();
  }

  @override
  void dispose() {
    _tickerMode?.removeListener(_update);
    AppForeground.visible.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (!mounted) return;
    final now =
        (_tickerMode?.value.enabled ?? true) && AppForeground.visible.value;
    if (now == _onScreen) return;
    _onScreen = now;
    didChangeOnScreen(now);
  }
}
