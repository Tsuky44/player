import 'package:flutter/material.dart';
import 'studio_drawer_shell.dart';

/// Side drawer for grid density, snap-to-grid, and modular layout toggle.
class LayoutSettingsDrawer extends StatelessWidget {
  final int horizontalSegments;
  final int verticalSegments;
  final bool snapToGrid;
  final bool useModularLayout;
  final bool tapToTogglePlayback;
  final ValueChanged<int> onGridPresetChanged;
  final ValueChanged<bool> onSnapToGridChanged;
  final ValueChanged<bool> onUseModularLayoutChanged;
  final ValueChanged<bool> onTapToTogglePlaybackChanged;

  const LayoutSettingsDrawer({
    super.key,
    required this.horizontalSegments,
    required this.verticalSegments,
    required this.snapToGrid,
    required this.useModularLayout,
    required this.tapToTogglePlayback,
    required this.onGridPresetChanged,
    required this.onSnapToGridChanged,
    required this.onUseModularLayoutChanged,
    required this.onTapToTogglePlaybackChanged,
  });

  int get _gridPreset {
    return switch ((horizontalSegments, verticalSegments)) {
      (16, 10) => 0,
      (32, 20) => 1,
      (64, 40) => 2,
      _ => 1,
    };
  }

  @override
  Widget build(BuildContext context) {
    return StudioDrawerShell(
      title: 'Disposition',
      icon: Icons.grid_on,
      subtitle: 'Grille d’édition et activation du lecteur modulaire.',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        children: [
          const Text(
            'Grille',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Grossier')),
              ButtonSegment(value: 1, label: Text('Moyen')),
              ButtonSegment(value: 2, label: Text('Fin')),
            ],
            selected: {_gridPreset},
            onSelectionChanged: (v) => onGridPresetChanged(v.first),
            style: SegmentedButton.styleFrom(
              backgroundColor: const Color(0xFF252525),
              foregroundColor: Colors.grey,
              selectedForegroundColor: Colors.white,
              selectedBackgroundColor: const Color(0xFF007AFF),
            ),
          ),
          const SizedBox(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: snapToGrid,
            onChanged: onSnapToGridChanged,
            activeColor: const Color(0xFF007AFF),
            secondary: Icon(
              snapToGrid ? Icons.auto_fix_normal : Icons.auto_fix_off,
              color: snapToGrid ? const Color(0xFF007AFF) : Colors.grey,
            ),
            title: const Text(
              'Alignement automatique',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
            subtitle: const Text(
              'Les contrôles accrochent à la grille la plus proche',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          const Divider(color: Color(0xFF2A2A2A), height: 1),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: useModularLayout,
            onChanged: onUseModularLayoutChanged,
            activeColor: const Color(0xFF007AFF),
            title: const Text(
              'Utiliser cette disposition dans le lecteur',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
            subtitle: const Text(
              'Désactivé = interface standard du lecteur',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: tapToTogglePlayback,
            onChanged: useModularLayout ? onTapToTogglePlaybackChanged : null,
            activeColor: const Color(0xFF007AFF),
            secondary: Icon(
              tapToTogglePlayback ? Icons.touch_app : Icons.touch_app_outlined,
              color: tapToTogglePlayback ? const Color(0xFF007AFF) : Colors.grey,
            ),
            title: const Text(
              'Tap sur l’écran = lecture / pause',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
            subtitle: Text(
              useModularLayout
                  ? 'Permet de retirer le bouton play/pause tout en gardant la pause au clic'
                  : 'Disponible uniquement avec le lecteur modulaire',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
