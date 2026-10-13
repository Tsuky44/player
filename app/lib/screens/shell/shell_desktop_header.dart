import 'package:flutter/material.dart';

import '../../desktop_window.dart';
import '../../l10n/tr.dart';
import '../../models/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_type.dart';
import '../../utils/app_platform.dart';
import '../../utils/window_controls.dart';
import '../../widgets/global/account_menu.dart';
import '../../widgets/global/app_download_button.dart';
import '../../widgets/global/glass_catalog_search.dart';
import '../../widgets/global/glass_chrome.dart';
import '../../widgets/global/interface_tour/tour_anchor.dart';
import 'shell_tabs.dart';

/// L'en-tête de verre des grands écrans : la marque, les onglets, la
/// recherche et le compte.
class ShellDesktopHeader extends StatelessWidget {
  /// L'identifiant de l'onglet affiché (voir [ShellTabs]).
  final String selected;
  final ValueChanged<String> onTabSelected;

  /// Les bibliothèques du serveur : un onglet chacune, sous son nom.
  final List<MediaLibrary> libraries;
  final HomeProvider homeProvider;
  final AuthProvider authProvider;

  /// Faux sur le web, où il n'y a pas d'espace de stockage applicatif : sans
  /// destination possible, l'onglet n'existe pas.
  final bool canDownload;

  /// Le nœud de focus d'un onglet, possédé par la coquille.
  final FocusNode Function(String tab) nodeFor;

  const ShellDesktopHeader({
    super.key,
    required this.selected,
    required this.onTabSelected,
    required this.libraries,
    required this.homeProvider,
    required this.authProvider,
    required this.canDownload,
    required this.nodeFor,
  });

  Widget _tab(String tab, String label) => GlassNavTab(
        label: label,
        selected: selected == tab,
        focusNode: nodeFor(tab),
        onTap: () => onTabSelected(tab),
      );

  @override
  Widget build(BuildContext context) {
    final header = SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          28,
          6 + macOSWindowControlsTopInset,
          28,
          10,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            GlassBrand(onTap: () => onTabSelected(ShellTabs.home)),
            const SizedBox(width: 20),
            // Le nombre de bibliothèques n'est pas borné : au-delà de la
            // place disponible leurs onglets défilent, sans pousser la
            // recherche ni le compte hors de l'en-tête.
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TourTarget(
                      anchor: TourAnchor.library,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _tab(ShellTabs.home, tr('Accueil')),
                          for (final library in libraries)
                            _tab(ShellTabs.library(library),
                                ShellTabs.label(library)),
                        ],
                      ),
                    ),
                    // The whole request catalog sits behind request_media
                    // server-side, so an account without it gets no entry
                    // point either.
                    if (authProvider.permissions.requestMedia)
                      TourTarget(
                        anchor: TourAnchor.requests,
                        child: _tab(ShellTabs.requests, tr('Demandes')),
                      ),
                    if (canDownload)
                      TourTarget(
                        anchor: TourAnchor.downloads,
                        child:
                            _tab(ShellTabs.downloads, tr('Téléchargements')),
                      ),
                  ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            const TourTarget(
              anchor: TourAnchor.search,
              child: GlassCatalogSearch(
                collapsedWidth: 200,
                expandedWidth: 280,
              ),
            ),
            const SizedBox(width: 12),
            _IndexerActions(homeProvider: homeProvider),
            const AppDownloadButton(),
            AccountMenu(authProvider: authProvider),
          ],
        ),
      ),
    );

    return GlassHeaderStrip(
      child: AppPlatform.isMacOS
          ? Stack(
              children: [
                // Empty zones (title bar / spacer) drag the window; buttons
                // above still receive hits and don't block trackpad scroll.
                const Positioned.fill(
                  child: WindowDragArea(child: SizedBox.expand()),
                ),
                header,
              ],
            )
          : header,
    );
  }
}

class _IndexerActions extends StatelessWidget {
  final HomeProvider homeProvider;

  const _IndexerActions({required this.homeProvider});

  @override
  Widget build(BuildContext context) {
    if (homeProvider.isScanning) {
      return _StatusBadge(label: tr('Scan…'));
    }
    if (homeProvider.isBackfillingMetadata) {
      return _StatusBadge(label: tr('Affiches…'));
    }
    if (homeProvider.isRedetectingAll) {
      final stats = homeProvider.redetectAllProgress;
      final label = stats.total > 0
          ? tr('Match {0}/{1}', [stats.processed, stats.total])
          : tr('Match…');
      return _StatusBadge(label: label);
    }
    if (homeProvider.isExtractingSubtitles) {
      final stats = homeProvider.subtitleStats;
      final label = stats.total > 0
          ? tr('Sous-titres {0}/{1}', [stats.processed, stats.total])
          : tr('Sous-titres…');
      return _StatusBadge(label: label);
    }
    return const SizedBox.shrink();
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;

  const _StatusBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.accent.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: AppColors.textMuted.withValues(alpha: 0.95),
                fontSize: AppType.caption,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
