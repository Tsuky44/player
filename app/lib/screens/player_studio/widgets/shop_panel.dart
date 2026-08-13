import 'package:flutter/material.dart';

import '../../../models/player_layout.dart';
import '../../../theme/app_colors.dart';

/// Category groups for the control shop.
const _kCategories = <String, List<PlayerControlType>>{
  'Barres de progression': [
    PlayerControlType.progressBar,
    PlayerControlType.timeline,
    PlayerControlType.timelineGlassInline,
    PlayerControlType.timelineEmby,
  ],
  'Navigation temporelle': [
    PlayerControlType.rewind,
    PlayerControlType.forward,
  ],
  'Lecture': [
    PlayerControlType.playPause,
  ],
  'Épisodes': [
    PlayerControlType.skipPrevious,
    PlayerControlType.skipNext,
    PlayerControlType.upNext,
    PlayerControlType.upNextEmby,
  ],
  'Volume': [
    PlayerControlType.volumeUp,
    PlayerControlType.volumeDown,
    PlayerControlType.mute,
    PlayerControlType.volumeSlider,
  ],
  'Contrôles généraux': [
    PlayerControlType.back,
    PlayerControlType.mediaTitle,
    PlayerControlType.mediaLogo,
    PlayerControlType.settings,
    PlayerControlType.subtitles,
    PlayerControlType.fullscreen,
  ],
  'Pack Cinéma': [
    PlayerControlType.skipIntro,
    PlayerControlType.playbackSpeed,
    PlayerControlType.aspectFit,
    PlayerControlType.audioTracks,
    PlayerControlType.chapters,
    PlayerControlType.timeRemaining,
    PlayerControlType.rewind30,
    PlayerControlType.forward30,
  ],
  'Pack Emby': [
    PlayerControlType.episodeTitleBlock,
    PlayerControlType.chaptersEmby,
    PlayerControlType.mediaInfo,
  ],
};

/// Bottom sheet that lists all available button variants so the user can
/// pick and add new controls to the canvas.
class ShopPanel extends StatelessWidget {
  final void Function(PlayerControlType type) onAdd;
  final Set<PlayerControlType> placedTypes;

  const ShopPanel({
    super.key,
    required this.onAdd,
    required this.placedTypes,
  });

  static bool _isTimelineBar(PlayerControlType type) => type.isTimelineBar;

  static bool _isPlaced(PlayerControlType type, Set<PlayerControlType> placed) {
    if (_isTimelineBar(type)) {
      return placed.any(_isTimelineBar);
    }
    return placed.contains(type);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 14, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: AppColors.glassBorder),
                  ),
                  child: const Icon(
                    Icons.widgets_outlined,
                    color: AppColors.textSecondary,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Boutique de contrôles',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Ajoute un élément au canvas du lecteur',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: AppColors.textSecondary, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: _kCategories.length,
                itemBuilder: (context, sectionIndex) {
                  final entry = _kCategories.entries.elementAt(sectionIndex);
                  final title = entry.key;
                  final types = entry.value;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                            childAspectRatio: 0.95,
                          ),
                          itemCount: types.length,
                          itemBuilder: (context, index) {
                            final type = types[index];
                            final isPlaced = _isPlaced(type, placedTypes);
                            return _ShopItem(
                              type: type,
                              isPlaced: isPlaced,
                              onTap: () {
                                onAdd(type);
                                Navigator.pop(context);
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShopItem extends StatelessWidget {
  final PlayerControlType type;
  final bool isPlaced;
  final VoidCallback onTap;

  const _ShopItem({
    required this.type,
    required this.isPlaced,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            color: isPlaced
                ? AppColors.primary.withValues(alpha: 0.10)
                : AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isPlaced
                  ? AppColors.primary.withValues(alpha: 0.45)
                  : AppColors.glassBorder,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.background.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.glassBorder),
                  ),
                  child: Icon(
                    type.icon,
                    color: AppColors.textPrimary,
                    size: 22,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  type.label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                    letterSpacing: -0.1,
                  ),
                ),
                const Spacer(),
                Text(
                  isPlaced ? 'Placé' : 'Ajouter',
                  style: TextStyle(
                    color: isPlaced ? AppColors.primary : AppColors.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
