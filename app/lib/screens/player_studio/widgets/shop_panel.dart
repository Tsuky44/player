import 'package:flutter/material.dart';
import '../../../models/player_layout.dart';

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
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.storefront, color: Color(0xFF007AFF), size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Boutique de contrôles',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Appuie sur un bouton pour l\'ajouter au canvas.',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: _kCategories.length,
                itemBuilder: (context, sectionIndex) {
                  final entry = _kCategories.entries.elementAt(sectionIndex);
                  final title = entry.key;
                  final types = entry.value;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                            childAspectRatio: 1.2,
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: isPlaced ? const Color(0xFF1A2A3A) : const Color(0xFF252525),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isPlaced ? const Color(0xFF007AFF) : Colors.white.withOpacity(0.08),
            width: isPlaced ? 2 : 1,
          ),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(type.icon, color: Colors.white, size: 28),
            const SizedBox(height: 8),
            Text(
              type.label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: isPlaced ? const Color(0xFF007AFF).withOpacity(0.3) : const Color(0xFF007AFF),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                isPlaced ? 'Déjà placé' : 'Ajouter',
                style: TextStyle(
                  color: isPlaced ? const Color(0xFF007AFF) : Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
