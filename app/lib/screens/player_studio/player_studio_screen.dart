import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/player_layout.dart';
import '../../providers/player_layout_provider.dart';
import '../../utils/responsive.dart';
import 'hooks/use_studio_controller.dart';
import 'widgets/studio_canvas.dart';
import 'widgets/shop_panel.dart';
import 'widgets/glass_style_drawer.dart';
import 'widgets/layout_settings_drawer.dart';
import 'widgets/control_edit_drawer.dart';
import 'widgets/studio_preview.dart';
import 'widgets/player_layouts_sheet.dart';
import 'widgets/player_template_picker_sheet.dart';
import 'widgets/fixed_chrome_preview.dart';

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

  void _openControlEditDrawer() {
    if (_controller.selectedId == null) return;
    _openDrawer(_StudioDrawerMode.control);
  }

  void _onLayoutProviderLoaded() {
    if (!_layoutProvider.isLoaded) return;
    _layoutProvider.removeListener(_onLayoutProviderLoaded);
    _controller.loadDraft(_layoutProvider.config);
  }

  void _onLayoutProviderChanged() {
    if (!mounted) return;
    final activeId = _layoutProvider.activePresetId;
    if (activeId != _boundPresetId) {
      _boundPresetId = activeId;
      _controller.loadDraft(_layoutProvider.config);
    }
  }

  String? _boundPresetId;

  @override
  void initState() {
    super.initState();
    _layoutProvider = context.read<PlayerLayoutProvider>();
    _boundPresetId = _layoutProvider.activePresetId;
    _controller = StudioController(
      _layoutProvider.isLoaded
          ? _layoutProvider.config
          : PlayerLayoutConfig.standard(),
    );
    if (!_layoutProvider.isLoaded) {
      _layoutProvider.addListener(_onLayoutProviderLoaded);
    }
    _layoutProvider.addListener(_onLayoutProviderChanged);
  }

  @override
  void dispose() {
    _layoutProvider.removeListener(_onLayoutProviderLoaded);
    _layoutProvider.removeListener(_onLayoutProviderChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await context.read<PlayerLayoutProvider>().replace(_controller.draft);
    if (!mounted) return;
    final name = context.read<PlayerLayoutProvider>().activePresetName;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('« $name » enregistré sur ton compte'),
        backgroundColor: const Color(0xFF0A84FF),
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
    final maxH = MediaQuery.of(context).size.height * (AppLayout.isCompact(context) ? 0.86 : 0.92);
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

  Widget _buildEndDrawer(bool compact) {
    switch (_drawerMode) {
      case _StudioDrawerMode.layout:
        return LayoutSettingsDrawer(
          horizontalSegments: _controller.horizontalSegments,
          verticalSegments: _controller.verticalSegments,
          snapToGrid: _controller.snapToGrid,
          useModularLayout: context.watch<PlayerLayoutProvider>().useModularLayout,
          tapToTogglePlayback: _controller.draft.tapToTogglePlayback,
          onGridPresetChanged: _onGridPresetChanged,
          onSnapToGridChanged: _controller.setSnapToGrid,
          onUseModularLayoutChanged: (v) =>
              context.read<PlayerLayoutProvider>().setUseModularLayout(v),
          onTapToTogglePlaybackChanged: _controller.setTapToTogglePlayback,
        );
      case _StudioDrawerMode.glass:
        return GlassStyleDrawer(
          skin: _controller.draft.skin,
          blurIntensity: _controller.draft.blurIntensity,
          glassOpacity: _controller.draft.glassOpacity,
          liquidGlass: _controller.draft.liquidGlass,
          flatAccentColor: _controller.draft.flatAccentColor,
          flatElevation: _controller.draft.flatElevation,
          neumorphicIntensity: _controller.draft.neumorphicIntensity,
          onSkinChanged: _controller.setSkin,
          onBlurChanged: _controller.setBlurIntensity,
          onOpacityChanged: _controller.setGlassOpacity,
          onLiquidGlassChanged: _controller.setLiquidGlass,
          onFlatAccentColorChanged: _controller.setFlatAccentColor,
          onFlatElevationChanged: _controller.setFlatElevation,
          onNeumorphicIntensityChanged: _controller.setNeumorphicIntensity,
        );
      case _StudioDrawerMode.control:
        return ControlEditDrawer(
          selectedPlaced: _controller.selectedPlaced,
          sizePercentage: _controller.selectedConfig?.sizePercentage,
          onSizePercentageChanged: _controller.setSelectedSizePercentage,
          widthPercentage: _controller.selectedConfig?.widthPercentage,
          onWidthPercentageChanged: _controller.setSelectedWidthPercentage,
          timelineOptions: _controller.selectedPlaced?.type.isTimelineBar == true
              ? _controller.selectedPlaced?.effectiveTimelineOptions
              : null,
          onTimelineOptionsChanged: _controller.selectedPlaced?.type.isTimelineBar == true
              ? _controller.setSelectedTimelineOptions
              : null,
          onDelete: _controller.selectedId == null
              ? null
              : () => _controller.removeControl(_controller.selectedId!),
        );
    }
  }

  List<Widget> _buildActions(BuildContext context, {required bool compact}) {
    final hasSelection = _controller.selectedId != null;

    if (compact) {
      return [
        IconButton(
          icon: const Icon(Icons.save_outlined, color: Color(0xFF0A84FF)),
          tooltip: 'Enregistrer',
          onPressed: _save,
        ),
        IconButton(
          icon: const Icon(Icons.add_shopping_cart, color: Colors.white),
          tooltip: 'Boutique',
          onPressed: () => _openShop(context),
        ),
        PopupMenuButton<String>(
          tooltip: 'Plus',
          color: const Color(0xFF1A1A1A),
          icon: const Icon(Icons.more_vert, color: Colors.white),
          onSelected: (value) {
            switch (value) {
              case 'layouts':
                showPlayerLayoutsSheet(context);
              case 'layout':
                _openDrawer(_StudioDrawerMode.layout);
              case 'size':
                if (hasSelection) _openControlEditDrawer();
              case 'glass':
                _openDrawer(_StudioDrawerMode.glass);
              case 'preview':
                _openPreview(context);
              case 'reset':
                _reset();
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'layouts', child: Text('Mes playeurs')),
            const PopupMenuItem(value: 'layout', child: Text('Disposition / grille')),
            PopupMenuItem(
              value: 'size',
              enabled: hasSelection,
              child: Text(
                'Taille du contrôle',
                style: TextStyle(
                  color: hasSelection ? Colors.white : Colors.white38,
                ),
              ),
            ),
            const PopupMenuItem(value: 'glass', child: Text('Style')),
            const PopupMenuItem(value: 'preview', child: Text('Aperçu plein écran')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'reset', child: Text('Réinitialiser')),
          ],
        ),
      ];
    }

    return [
      IconButton(
        icon: const Icon(Icons.dashboard_customize_outlined, color: Colors.white),
        tooltip: 'Mes playeurs',
        onPressed: () => showPlayerLayoutsSheet(context),
      ),
      IconButton(
        icon: const Icon(Icons.grid_on, color: Colors.white),
        tooltip: 'Disposition',
        onPressed: () => _openDrawer(_StudioDrawerMode.layout),
      ),
      IconButton(
        icon: Icon(
          Icons.straighten,
          color: hasSelection ? Colors.white : Colors.white38,
        ),
        tooltip: 'Taille du contrôle',
        onPressed: hasSelection ? _openControlEditDrawer : null,
      ),
      IconButton(
        icon: const Icon(Icons.palette_outlined, color: Colors.white),
        tooltip: 'Style',
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
            backgroundColor: const Color(0xFF0A84FF),
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
    ];
  }

  @override
  Widget build(BuildContext context) {
    final compact = AppLayout.isCompact(context);
    final pad = compact ? 12.0 : 24.0;
    final drawerWidth = compact
        ? MediaQuery.sizeOf(context).width.clamp(280.0, 360.0)
        : 320.0;

    // A fixed chrome has nothing to edit, so the Studio drops to a frozen
    // preview: no shop, no drag handles, no appearance drawers.
    final fixedChrome = context.watch<PlayerLayoutProvider>().fixedChrome;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: const Color(0xFF0D0D0D),
          endDrawer: Drawer(
            width: drawerWidth,
            backgroundColor: const Color(0xFF1A1A1A),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => _buildEndDrawer(compact),
            ),
          ),
          appBar: AppBar(
            backgroundColor: const Color(0xFF1F1F1F),
            titleSpacing: compact ? 0 : null,
            title: Consumer<PlayerLayoutProvider>(
              builder: (context, layout, _) {
                return InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => showPlayerLayoutsSheet(context),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 4 : 0,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            layout.activePresetName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: compact ? 16 : null),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.expand_more,
                          size: 20,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            actions: fixedChrome != null
                ? [
                    IconButton(
                      icon: const Icon(Icons.layers_outlined,
                          color: Colors.white),
                      tooltip: 'Mes playeurs',
                      onPressed: () => showPlayerLayoutsSheet(context),
                    ),
                  ]
                : _buildActions(context, compact: compact),
          ),
          body: Padding(
            padding: EdgeInsets.fromLTRB(
              pad,
              compact ? 8 : 24,
              pad,
              pad + MediaQuery.paddingOf(context).bottom,
            ),
            child: Center(
              child: fixedChrome != null
                  ? FixedChromePreview(
                      chrome: fixedChrome,
                      onCreateModular: () => showPlayerTemplatePicker(context),
                    )
                  : StudioCanvas(
                      controller: _controller,
                      onOpenFullControlEditor: _openControlEditDrawer,
                    ),
            ),
          ),
        );
      },
    );
  }
}
