import 'package:flutter/material.dart';

import 'onyx/onyx_settings_menu.dart';
import 'player_settings_anchor.dart';

/// Où poser le menu des réglages : au-dessus (ou au-dessous) du bouton qui
/// l'a ouvert, au centre s'il n'a pas pu être mesuré.
typedef SettingsPopupPlacement = ({
  double left,
  double? top,
  double? bottom,
  double maxHeight,
});

/// Mesuré une fois, à l'ouverture : le menu reste où il est apparu.
SettingsPopupPlacement placeSettingsPopup(GlobalKey anchorKey, Size screenSize) {
  final renderBox = anchorKey.currentContext?.findRenderObject() as RenderBox?;
  const menuWidth = OnyxSettingsMenu.width;
  const menuMaxHeight = OnyxSettingsMenu.maxHeight;

  if (renderBox == null) {
    return (
      left: (screenSize.width - menuWidth) / 2,
      top: (screenSize.height - menuMaxHeight) / 2,
      bottom: null,
      maxHeight: menuMaxHeight,
    );
  }
  final buttonRect = renderBox.localToGlobal(Offset.zero) & renderBox.size;
  final vertical = PlayerSettingsAnchor.verticalPlacement(
    buttonRect: buttonRect,
    screenSize: screenSize,
    popupMaxHeight: menuMaxHeight,
  );
  return (
    left: PlayerSettingsAnchor.horizontalLeft(
      buttonRect: buttonRect,
      screenSize: screenSize,
      popupWidth: menuWidth,
    ),
    top: vertical.top,
    bottom: vertical.bottom,
    maxHeight: vertical.maxHeight,
  );
}

/// Le menu des réglages par-dessus le lecteur : un tap à côté le ferme.
class PlayerSettingsPopup extends StatelessWidget {
  const PlayerSettingsPopup({
    super.key,
    required this.placement,
    required this.screenSize,
    required this.onDismiss,
    required this.child,
  });

  final SettingsPopupPlacement placement;
  final Size screenSize;
  final VoidCallback onDismiss;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onDismiss,
      behavior: HitTestBehavior.translucent,
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox(
          width: screenSize.width,
          height: screenSize.height,
          child: Stack(
            children: [
              Positioned(
                left: placement.left,
                bottom: placement.bottom,
                top: placement.top,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: placement.maxHeight),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Un panneau au centre du lecteur : un tap à côté le ferme, un tap dedans
/// non.
class PlayerCenteredPopup extends StatelessWidget {
  const PlayerCenteredPopup({
    super.key,
    required this.onDismiss,
    required this.child,
  });

  final VoidCallback onDismiss;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onDismiss,
      behavior: HitTestBehavior.translucent,
      child: Material(
        type: MaterialType.transparency,
        child: Center(
          child: GestureDetector(
            // Un tap dans le panneau ne doit pas le fermer.
            onTap: () {},
            child: child,
          ),
        ),
      ),
    );
  }
}
