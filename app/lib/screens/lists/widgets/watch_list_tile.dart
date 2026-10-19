import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/tr.dart';
import '../../../models/watch_list.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_icons.dart';
import '../../../theme/app_motion.dart';
import '../../../theme/app_type.dart';
import '../../../tv/tv_focus.dart';
import '../../../utils/poster_url.dart';
import '../../../widgets/global/app_network_image.dart';

/// Ce que la vignette dit d'une liste sous son nom : combien de titres, et à
/// qui elle est — « Partagée », « Privée », ou le nom de son propriétaire.
String watchListCaption(WatchList list) {
  final count =
      list.itemCount == 1 ? tr('1 titre') : tr('{0} titres', [list.itemCount]);
  if (!list.isMine) return tr('{0} · par {1}', [count, list.owner.username]);
  return '$count · ${list.isShared ? tr('Partagée') : tr('Privée')}';
}

/// La vignette d'une liste : les affiches de ses derniers ajouts en mosaïque,
/// son nom et sa légende.
class WatchListTile extends StatefulWidget {
  const WatchListTile({
    super.key,
    required this.list,
    required this.onTap,
    this.autofocus = false,
  });

  final WatchList list;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  State<WatchListTile> createState() => _WatchListTileState();
}

class _WatchListTileState extends State<WatchListTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final list = widget.list;
    final baseUrl = context.read<ApiClient>().baseUrl;
    final posters = [
      for (final p in list.posters) cardPosterUrl(p, serverBaseUrl: baseUrl),
    ];
    return Semantics(
      button: true,
      label: tr('Ouvrir la liste {0}', [list.displayName]),
      excludeSemantics: true,
      // La télécommande arrive par TvFocusable ; le contour de la mosaïque dit
      // le focus, pas un second anneau autour du nom.
      child: TvFocusable(
        autofocus: widget.autofocus,
        onSelect: widget.onTap,
        focusScale: 1.0,
        showRing: false,
        onFocusChange: (f) => setState(() => _focused = f),
        child: InkWell(
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(14),
          onTap: widget.onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AnimatedContainer(
                  duration: AppMotion.fade(context),
                  curve: AppMotion.curve,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _focused ? AppColors.accent : AppColors.border,
                      width: _focused ? 2 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: posters.isEmpty
                      ? Center(
                          child: Icon(
                            list.isWatchLater
                                ? AppIcons.addToList
                                : AppIcons.lists,
                            size: 40,
                            color: AppColors.textMuted,
                          ),
                        )
                      : _Mosaic(urls: posters),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (list.isWatchLater) ...[
                    const Icon(AppIcons.inList,
                        size: 16, color: AppColors.textPrimary),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      list.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: AppType.callout,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                watchListCaption(list),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.textMuted, fontSize: AppType.footnote),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Jusqu'à quatre affiches côte à côte : une liste se reconnaît à ce qu'elle
/// contient.
class _Mosaic extends StatelessWidget {
  const _Mosaic({required this.urls});

  final List<String?> urls;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth / urls.length;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final url in urls)
              Expanded(
                child: AppNetworkImage(
                  url: url,
                  fit: BoxFit.cover,
                  decodeWidth: width,
                  placeholder: const ColoredBox(color: AppColors.surface),
                  errorWidget: const ColoredBox(color: AppColors.surface),
                ),
              ),
          ],
        );
      },
    );
  }
}
