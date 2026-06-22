import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/player_layout_provider.dart';
import 'hooks/use_studio_controller.dart';
import 'widgets/studio_canvas.dart';
import 'widgets/control_size_slider.dart';
import 'widgets/shop_panel.dart';
import 'widgets/studio_preview.dart';

/// "Player Studio": a dedicated screen to visually customize the layout
/// (position + size) of the player controls, then persist it.
class PlayerStudioScreen extends StatefulWidget {
  const PlayerStudioScreen({super.key});

  @override
  State<PlayerStudioScreen> createState() => _PlayerStudioScreenState();
}

class _PlayerStudioScreenState extends State<PlayerStudioScreen> {
  late final StudioController _controller;

  @override
  void initState() {
    super.initState();
    final layout = context.read<PlayerLayoutProvider>().config;
    _controller = StudioController(layout);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await context.read<PlayerLayoutProvider>().replace(_controller.draft);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Disposition enregistrée'),
        backgroundColor: Color(0xFF007AFF),
      ),
    );
  }

  void _reset() {
    _controller.resetDraft();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Disposition par défaut restaurée')),
    );
  }

  void _openShop(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.92;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SizedBox(
        height: maxH,
        child: ShopPanel(
          onAdd: (type) => _controller.addControl(type),
          placedTypes: _controller.draft.controls.map((c) => c.type).toSet(),
        ),
      ),
    );
  }

  void _openPreview(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StudioPreview(config: _controller.draft),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F1F1F),
        title: const Text('Player Studio'),
        actions: [
          TextButton.icon(
            onPressed: _reset,
            icon: const Icon(Icons.restart_alt, color: Colors.grey, size: 20),
            label: const Text('Réinitialiser', style: TextStyle(color: Colors.grey)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ElevatedButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('Enregistrer'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF007AFF),
                foregroundColor: Colors.white,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.fullscreen, color: Colors.white),
            tooltip: 'Aperçu plein écran',
            onPressed: () => _openPreview(context),
          ),
          IconButton(
            icon: const Icon(Icons.add_shopping_cart, color: Colors.white),
            tooltip: 'Boutique',
            onPressed: () => _openShop(context),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Row(
              children: [
                const Icon(Icons.grid_on, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                const Text('Grille', style: TextStyle(color: Colors.grey, fontSize: 13)),
                const SizedBox(width: 12),
                Expanded(
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      return SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 0, label: Text('Grossier')),
                          ButtonSegment(value: 1, label: Text('Moyen')),
                          ButtonSegment(value: 2, label: Text('Fin')),
                        ],
                        selected: {
                          switch ((_controller.horizontalSegments, _controller.verticalSegments)) {
                            (16, 10) => 0,
                            (32, 20) => 1,
                            (64, 40) => 2,
                            _ => 1,
                          }
                        },
                        onSelectionChanged: (v) {
                          final idx = v.first;
                          final (h, vSeg) = switch (idx) {
                            0 => (16, 10),
                            1 => (32, 20),
                            2 => (64, 40),
                            _ => (32, 20),
                          };
                          _controller.setGridSegments(h, vSeg);
                        },
                        style: SegmentedButton.styleFrom(
                          backgroundColor: const Color(0xFF1A1A1A),
                          foregroundColor: Colors.grey,
                          selectedForegroundColor: Colors.white,
                          selectedBackgroundColor: const Color(0xFF007AFF),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return SwitchListTile(
                value: _controller.snapToGrid,
                onChanged: _controller.setSnapToGrid,
                activeColor: const Color(0xFF007AFF),
                title: const Text(
                  'Alignement automatique',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
                subtitle: const Text(
                  'Les contrôles accrochent à la grille la plus proche',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                secondary: Icon(
                  _controller.snapToGrid ? Icons.auto_fix_normal : Icons.auto_fix_off,
                  color: _controller.snapToGrid ? const Color(0xFF007AFF) : Colors.grey,
                ),
              );
            },
          ),
          const Divider(color: Color(0xFF2A2A2A), height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SwitchListTile(
              value: context.watch<PlayerLayoutProvider>().useModularLayout,
              onChanged: (v) =>
                  context.read<PlayerLayoutProvider>().setUseModularLayout(v),
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
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: StudioCanvas(controller: _controller),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return ControlSizeSlider(
                selectedPlaced: _controller.selectedPlaced,
                sizePercentage: _controller.selectedConfig?.sizePercentage,
                onSizePercentageChanged: _controller.setSelectedSizePercentage,
                widthPercentage: _controller.selectedConfig?.widthPercentage,
                onWidthPercentageChanged: _controller.setSelectedWidthPercentage,
                onDelete: _controller.selectedId == null
                    ? null
                    : () => _controller.removeControl(_controller.selectedId!),
              );
            },
          ),
        ],
      ),
    );
  }
}
