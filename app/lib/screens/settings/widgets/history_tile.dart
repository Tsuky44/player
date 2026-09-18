import 'package:flutter/material.dart';

import '../../../models/server_activity.dart';
import '../../../theme/app_colors.dart';
import 'media_thumb.dart';
import 'settings_ui.dart';

/// Une lecture de l'historique : le titre, qui, où, quand et combien de temps.
class HistoryTile extends StatelessWidget {
  const HistoryTile(this.entry, {super.key, this.showUser = true, this.onTap});

  final PlaybackHistoryEntry entry;
  final bool showUser;

  /// Ouvre le journal de cette lecture. Null pour un compte qui n'a pas le
  /// droit de les lire : la ligne reste alors inerte plutôt que de mener à un
  /// 403.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final progress = entry.durationSeconds <= 0
        ? null
        : (entry.positionSeconds / entry.durationSeconds).clamp(0.0, 1.0);
    final clock =
        '${entry.startedAt.hour.toString().padLeft(2, '0')}:${entry.startedAt.minute.toString().padLeft(2, '0')}';

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          MediaThumb(
            posterUrl: entry.posterUrl,
            width: 36,
            isShow: entry.showTitle.isNotEmpty,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.detail.isEmpty
                      ? entry.headline
                      : '${entry.headline} · ${entry.subtitle}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    if (showUser) ...[
                      UserAvatar(entry.username, size: 16),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        [
                          if (showUser) entry.username,
                          if (entry.deviceName.isNotEmpty) entry.deviceName,
                          relativeTime(entry.startedAt),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatWatchTime(entry.watchedSeconds),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: '${entry.playMethod.label} · début $clock',
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: playMethodColor(entry.playMethod),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  if (progress != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      '${(progress * 100).round()} %',
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 11.5),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ],
      ),
    );

    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}
