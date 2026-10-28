import 'package:flutter/material.dart';

import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../theme/app_motion.dart';
import '../../widgets/global/account_menu.dart';
import '../../widgets/global/app_download_button.dart';
import '../../widgets/global/glass_chrome.dart';
import '../../widgets/global/sticky_glass_search.dart';

/// La barre du haut du téléphone, la même sur chaque onglet, accueil compris :
/// le logo (il ramène à l'accueil), la recherche, l'application à télécharger,
/// le compte.
///
/// L'accueil avait sa propre barre avec « ONYX » écrit, les autres onglets une
/// barre sans logo et une recherche calée à droite : on changeait de barre en
/// changeant d'onglet. Elle flottait aussi sans fond, et les affiches
/// défilaient sous l'avatar et le champ de recherche. Elle prend désormais le
/// verre de la barre d'onglets dès que la page a quitté son haut ([scrolled]).
/// En haut de page, un voile sombre léger garde les icônes lisibles sur
/// l'affiche de l'accueil ; sur les autres onglets le fond est déjà noir et il
/// ne se voit pas.
class MobileTopBar extends StatelessWidget {
  final bool scrolled;
  final AuthProvider authProvider;
  final HomeProvider homeProvider;
  final VoidCallback onLogoTap;

  const MobileTopBar({
    super.key,
    required this.scrolled,
    required this.authProvider,
    required this.homeProvider,
    required this.onLogoTap,
  });

  @override
  Widget build(BuildContext context) {
    final working = homeProvider.isScanning ||
        homeProvider.isBackfillingMetadata ||
        homeProvider.isRedetectingAll ||
        homeProvider.isExtractingSubtitles;
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: scrolled ? 0 : 1,
              duration: AppMotion.fade(context),
              curve: AppMotion.curve,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.5),
                      Colors.black.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
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
                GlassBrand(showWordmark: false, onTap: onLogoTap),
                const SizedBox(width: 12),
                const Expanded(child: InlineCatalogSearch()),
                const SizedBox(width: 4),
                if (working)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
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
