import 'package:flutter/material.dart';

import '../../../l10n/tr.dart';
import '../../../models/media_share.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_type.dart';
import '../../../utils/format.dart';
import 'settings_ui.dart';

/// Qui regarde un lien de partage et où chacun en est, sous la ligne du lien
/// dans « Liens de partage » (ADR-0066). Le serveur décide de « vu » et du
/// dernier média ; cette liste ne fait que l'écrire.
class ShareViewersList extends StatelessWidget {
  const ShareViewersList(this.viewers, {super.key, this.now});

  final List<MediaShareViewer> viewers;

  /// Injectable pour que « hier à 21:04 » se teste sans figer l'horloge.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    // Aligné sur le titre de la ligne du lien : la marge de SettingsTile (16),
    // l'affiche (36) et l'écart qui la suit (14).
    return Padding(
      padding: const EdgeInsets.fromLTRB(66, 0, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final viewer in viewers)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(Icons.person_outline_rounded,
                        size: 16, color: AppColors.textMuted),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: viewer.name,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextSpan(text: '  ${shareViewerProgress(viewer, now: now)}'),
                      ]),
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: AppType.subhead,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Où en est un spectateur : « S1 E3 · à 24:10 · hier à 21:04 », « S1 E1 ·
/// vu · il y a 5 min », et pour un film « à 01:02:10 » ou « Vu ».
String shareViewerProgress(MediaShareViewer viewer, {DateTime? now}) {
  final parts = <String>[];
  if (viewer.isEpisode) {
    parts.add(tr('S{0} E{1}', [viewer.seasonNumber, viewer.episodeNumber]));
  }
  if (viewer.finished) {
    parts.add(parts.isEmpty ? tr('Vu') : tr('vu'));
  } else if (viewer.positionSeconds > 0) {
    parts.add(tr('à {0}', [formatPlaybackTime(viewer.positionSeconds)]));
  }
  final at = viewer.watchedAt;
  if (at != null) parts.add(relativeTime(at, now: now));
  return parts.join(' · ');
}
