import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Une zone de l'image pilotée à la souris : le clic agit au relâchement.
///
/// Un `GestureDetector` avec `onTap`, `onDoubleTap` et `onPanStart` faisait
/// deux choses de travers sur un desktop :
///
/// - le clic attendait `kDoubleTapTimeout` (300 ms) pour être sûr qu'aucun
///   second clic ne suivait, et la pause arrivait avec ce retard ;
/// - le pan réclame une souris dès 2 px de mouvement
///   (`kPrecisePointerPanSlop`, non réglable). Une main qui bouge à peine en
///   cliquant perdait le clic au profit du déplacement de fenêtre, et il
///   fallait cliquer une seconde fois.
///
/// Ici le pointeur est observé, pas disputé : le clic part au relâchement, le
/// double-clic est le second clic d'une paire (il rejoue donc [onClick], ce qui
/// annule le premier, puis appelle [onDoubleClick]), et le glissement ne
/// commence qu'au-delà de [dragSlop].
///
/// [onDrag] reçoit de quoi savoir si le bouton est encore enfoncé : ce qu'il
/// déclenche peut attendre le système (sortir du plein écran), et lancer le
/// déplacement d'une fenêtre après le relâchement la laisse accrochée au
/// curseur jusqu'au clic suivant, qui est alors perdu.
typedef PointerDragStart = void Function(bool Function() stillHeld);

class PointerClickZone extends StatefulWidget {
  const PointerClickZone({
    super.key,
    required this.onClick,
    required this.onDoubleClick,
    required this.onDrag,
  });

  final VoidCallback onClick;
  final VoidCallback? onDoubleClick;

  /// Null where there is nothing to drag.
  final PointerDragStart? onDrag;

  /// Assez pour absorber le tremblement d'un clic, assez peu pour qu'un
  /// déplacement de fenêtre parte sans se faire sentir.
  static const double dragSlop = 8;

  @override
  State<PointerClickZone> createState() => _PointerClickZoneState();
}

class _PointerClickZoneState extends State<PointerClickZone> {
  int? _pointer;

  /// Le bouton enfoncé, y compris une fois le glissement parti.
  int? _held;
  Offset _downAt = Offset.zero;

  /// Court pendant qu'un second clic ferait un double-clic.
  Timer? _secondClickWindow;
  Offset _lastClickAt = Offset.zero;

  @override
  void dispose() {
    _secondClickWindow?.cancel();
    super.dispose();
  }

  void _down(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) return;
    _pointer = event.pointer;
    _held = event.pointer;
    _downAt = event.position;
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if ((event.position - _downAt).distance <= PointerClickZone.dragSlop) {
      return;
    }
    _pointer = null;
    final pointer = event.pointer;
    widget.onDrag?.call(() => mounted && _held == pointer);
  }

  void _up(PointerUpEvent event) {
    if (event.pointer == _held) _held = null;
    if (event.pointer != _pointer) return;
    _pointer = null;
    widget.onClick();

    final second = (_secondClickWindow?.isActive ?? false) &&
        (event.position - _lastClickAt).distance <= kDoubleTapSlop;
    _secondClickWindow?.cancel();
    if (second) {
      widget.onDoubleClick?.call();
      return;
    }
    _lastClickAt = event.position;
    _secondClickWindow = Timer(kDoubleTapTimeout, () {});
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: (_) => _pointer = _held = null,
      child: const SizedBox.expand(),
    );
  }
}
