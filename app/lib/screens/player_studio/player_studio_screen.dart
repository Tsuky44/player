import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/player_layout.dart';
import '../../providers/player_layout_provider.dart';
import 'hooks/use_studio_controller.dart';
import 'widgets/studio_canvas.dart';
import 'widgets/shop_panel.dart';
import 'widgets/glass_style_drawer.dart';
import 'widgets/layout_settings_drawer.dart';
import 'widgets/control_edit_drawer.dart';
import 'widgets/studio_preview.dart';

enum _StudioDrawerMode { layout, glass, control }

/// "Player Studio": a dedicated screen to visually customize the layout
/// (position + size) of the player controls, then persist it.
class PlayerStudioScreen extends StatefulWidget {
  const PlayerStudioScreen({super.key});

  @override
  State<PlayerStudioScreen> createState() => _PlayerStudioScreenState();
}

class _PlayerStudioScreenState extends State<PlayerStudioScreen> {
  late final StudioController _controller;
  late final PlayerLayoutProvider _layoutProvider;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  _StudioDrawerMode _drawerMode = _StudioDrawerMode.layout;

  void _openDrawer(_StudioDrawerMode mode) {
    setState(() => _drawerMode = mode);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scaffoldKey.currentState?.openEndDrawer();
    });
  }

  String? _lastOpenedControlId;

  void _onControlSelected() {
    final id = _controller.selectedId;
    if (id != null && id != _lastOpenedControlId) {
      _lastOpenedControlId = id;
      _openDrawer(_StudioDrawerMode.control);
    } else if (id == null) {
      _lastOpenedControlId = null;
    }
  }

  void _onLayoutProviderLoaded() {
    if (!_layoutProvider.isLoaded) return;
    _layoutProvider.removeListener(_onLayoutProviderLoaded);
    _controller.loadDraft(_layoutProvider.config);
  }

  @override
  void initState() {
    super.initState();
    _layoutProvider = context.read<PlayerLayoutProvider>();
    _controller = StudioController(
      _layoutProvider.isLoaded
          ? _layoutProvider.config
          : PlayerLayoutConfig.standard(),
    );
    if (!_layoutProvider.isLoaded) {
      _layoutProvider.addListener(_onLayoutProviderLoaded);
    }
    _controller.addListener(_onControlSelected);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControlSelected);
    _layoutProvider.removeListener(_onLayoutProviderLoaded);
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

  void _onGridPresetChanged(int preset) {
    final (h, vSeg) = switch (preset) {
      0 => (16, 10),
      1 => (32, 20),
      2 => (64, 40),
      _ => (32, 20),
    };
    _controller.setGridSegments(h, vSeg);
  }

  Widget _buildEndDrawer() {
    switch (_drawerMode) {
      case _StudioDrawerMode.layout:
        return LayoutSettingsDrawer(
          horizontalSegments: _controller.horizontalSegments,
          verticalSegments: _controller.verticalSegments,
          snapToGrid: _controller.snapToGrid,
          useModularLayout: context.watch<PlayerLayoutProvider>().useModularLayout,
          onGridPresetChanged: _onGridPresetChanged,
          onSnapToGridChanged: _controller.setSnapToGrid,
          onUseModularLayoutChanged: (v) =>
              context.read<PlayerLayoutProvider>().setUseModularLayout(v),
        );
      case _StudioDrawerMode.glass:
        return GlassStyleDrawer(
          blurIntensity: _controller.draft.blurIntensity,
          glassOpacity: _controller.draft.glassOpacity,
          liquidGlass: _controller.draft.liquidGlass,
          onBlurChanged: _controller.setBlurIntensity,
          onOpacityChanged: _controller.setGlassOpacity,
          onLiquidGlassChanged: _controller.setLiquidGlass,
        );
      case _StudioDrawerMode.control:
        return ControlEditDrawer(
          selectedPlaced: _controller.selectedPlaced,
          sizePercentage: _controller.selectedConfig?.sizePercentage,
          onSizePercentageChanged: _controller.setSelectedSizePercentage,
          widthPercentage: _controller.selectedConfig?.widthPercentage,
          onWidthPercentageChanged: _controller.setSelectedWidthPercentage,
          onDelete: _controller.selectedId == null
              ? null
              : () => _controller.removeControl(_controller.selectedId!),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFF0D0D0D),
      endDrawer: Drawer(
        width: 320,
        backgroundColor: const Color(0xFF1A1A1A),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => _buildEndDrawer(),
        ),
      ),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F1F1F),
        title: const Text('Player Studio'),
        actions: [
          IconButton(
            icon: const Icon(Icons.grid_on, color: Colors.white),
            tooltip: 'Disposition',
            onPressed: () => _openDrawer(_StudioDrawerMode.layout),
          ),
          IconButton(
            icon: Icon(
              Icons.straighten,
              color: _controller.selectedId != null
                  ? Colors.white
                  : Colors.white38,
            ),
            tooltip: 'Taille du contrôle',
            onPressed: _controller.selectedId != null
                ? () => _openDrawer(_StudioDrawerMode.control)
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.blur_on, color: Colors.white),
            tooltip: 'Effet de verre',
            onPressed: () => _openDrawer(_StudioDrawerMode.glass),
          ),
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
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: StudioCanvas(controller: _controller),
        ),
      ),
        );
      },
    );
  }
}
