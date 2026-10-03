import 'package:flutter/material.dart';

import '../../providers/auth_provider.dart';
import '../../theme/app_motion.dart';
import '../../widgets/global/account_menu.dart';
import '../../widgets/global/app_download_button.dart';
import '../../widgets/global/glass_chrome.dart';
import '../../widgets/global/sticky_glass_search.dart';

/// La barre du haut des onglets autres que l'accueil, sur téléphone :
/// recherche, application à télécharger, compte.
///
/// Elle flottait sans fond, et les affiches défilaient sous l'avatar et le
/// champ de recherche. Elle prend désormais le verre de la barre d'onglets dès
/// que la page a quitté son haut ([scrolled]) — et seulement alors : en haut
/// de page, le titre du catalogue est juste dessous, et une bande vide par
/// dessus ne ferait qu'alourdir.
class MobileTopBar extends StatelessWidget {
  final bool scrolled;
  final AuthProvider authProvider;

  const MobileTopBar({
    super.key,
    required this.scrolled,
    required this.authProvider,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              key: const ValueKey('mobile-top-bar-glass'),
              opacity: scrolled ? 1 : 0,
              duration: AppMotion.fade(context),
              curve: AppMotion.curve,
              child: const GlassBarSurface(
                edge: AxisDirection.down,
                child: SizedBox.expand(),
              ),
            ),
          ),
        ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
            child: Row(
              children: [
                const Spacer(),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: const InlineCatalogSearch(),
                ),
                const SizedBox(width: 4),
                const AppDownloadButton(),
                AccountMenu(authProvider: authProvider),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Signale quand la liste verticale principale de [child] quitte son haut, ou
/// y revient.
///
/// Ne lit que la profondeur 0 : les rangées horizontales et les listes
/// imbriquées défilent sans que la page, elle, ait bougé.
class ScrollEdgeListener extends StatefulWidget {
  final Widget child;
  final ValueChanged<bool> onScrolledChanged;

  const ScrollEdgeListener({
    super.key,
    required this.child,
    required this.onScrolledChanged,
  });

  /// Au-delà de quelques pixels seulement : un rebond iOS en haut de page ne
  /// doit pas faire clignoter le verre.
  static const double threshold = 8;

  @override
  State<ScrollEdgeListener> createState() => _ScrollEdgeListenerState();
}

class _ScrollEdgeListenerState extends State<ScrollEdgeListener> {
  bool _scrolled = false;

  bool _onNotification(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final scrolled = notification.metrics.pixels > ScrollEdgeListener.threshold;
    if (scrolled != _scrolled) {
      _scrolled = scrolled;
      widget.onScrolledChanged(scrolled);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: widget.child,
    );
  }
}
