import 'dart:math' show Random;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import '../../../models/player_layout.dart';
import '../utils/alignment_guides.dart';

/// Editing logic for the Player Studio canvas.
///
/// Operates on a local DRAFT layout so changes are non-destructive until the
/// user explicitly saves. Translates pixel drag deltas into relative
/// percentages, enforces size boundaries, and snaps positions to a grid for
/// effortless alignment.
class StudioController extends ChangeNotifier {
  PlayerLayoutConfig _draft;
  String? _selectedId;

  /// Whether new drag positions should snap to the grid.
  bool _snapToGrid = true;

  /// How many vertical/horizontal divisions the canvas is split into.
  int _horizontalSegments = 32;
  int _verticalSegments = 20;

  /// True while the user is actively dragging (used for real-time UI).
  bool _isDragging = false;

  /// Magenta alignment lines shown while dragging near another control.
  List<StudioAlignmentGuide> _activeGuides = const [];

  StudioController(PlayerLayoutConfig initial) : _draft = initial;

  PlayerLayoutConfig get draft => _draft;
  String? get selectedId => _selectedId;

  PlacedControl? get selectedPlaced =>
      _selectedId == null ? null : _draft.byId(_selectedId!);

  ControlConfig? get selectedConfig => selectedPlaced?.config;

  PlayerControlType? get selectedType => selectedPlaced?.type;

  bool get snapToGrid => _snapToGrid;
  int get horizontalSegments => _horizontalSegments;
  int get verticalSegments => _verticalSegments;
  bool get isDragging => _isDragging;
  List<StudioAlignmentGuide> get activeGuides => _activeGuides;

  void select(String? id) {
    if (id != null && _draft.byId(id) != null) {
      _draft = _draft.withControlBroughtToFront(id);
    }
    _selectedId = id;
    notifyListeners();
  }

  void setSnapToGrid(bool value) {
    _snapToGrid = value;
    notifyListeners();
  }

  void setGridSegments(int horizontal, int vertical) {
    _horizontalSegments = horizontal.clamp(2, 64);
    _verticalSegments = vertical.clamp(2, 40);
    notifyListeners();
  }

  /// Update the frosted-glass blur intensity for all controls (draft only).
  void setBlurIntensity(double value) {
    _draft = _draft.copyWith(blurIntensity: value);
    notifyListeners();
  }

  /// Update the frosted-glass background opacity for all controls (draft only).
  void setGlassOpacity(double value) {
    _draft = _draft.copyWith(glassOpacity: value);
    notifyListeners();
  }

  void setLiquidGlass(bool value) {
    _draft = _draft.copyWith(liquidGlass: value);
    notifyListeners();
  }

  /// Switch the whole preset's control skin (draft only). Any placed
  /// [PlayerControlType.timeline] bar is kept in sync so the transport pill
  /// always matches the buttons around it.
  void setSkin(ControlSkinStyle value) {
    final matchingVisualStyle = switch (value) {
      ControlSkinStyle.glass => TimelineVisualStyle.glass,
      ControlSkinStyle.flat => TimelineVisualStyle.flat,
      ControlSkinStyle.neumorphic => TimelineVisualStyle.neumorphic,
    };
    final syncedControls = [
      for (final c in _draft.controls)
        if (c.type == PlayerControlType.timeline)
          c.copyWith(
            config: c.config.copyWith(
              timelineOptions: c.effectiveTimelineOptions
                  .copyWith(visualStyle: matchingVisualStyle),
            ),
          )
        else
          c,
    ];
    _draft = _draft.copyWith(controls: syncedControls, skin: value);
    notifyListeners();
  }

  void setFlatAccentColor(Color value) {
    _draft = _draft.copyWith(flatAccentColor: value);
    notifyListeners();
  }

  void setFlatElevation(FlatElevation value) {
    _draft = _draft.copyWith(flatElevation: value);
    notifyListeners();
  }

  void setNeumorphicIntensity(double value) {
    _draft = _draft.copyWith(neumorphicIntensity: value);
    notifyListeners();
  }

  void setTapToTogglePlayback(bool value) {
    _draft = _draft.copyWith(tapToTogglePlayback: value);
    notifyListeners();
  }

  /// Snap a raw percentage to the nearest grid line.
  double _snap(double raw, int segments) {
    final step = 1.0 / segments;
    return ((raw / step).round() * step).clamp(0.0, 1.0);
  }

  /// Move a control by a pixel [delta] measured inside a [canvas] of known size.
  /// Shows center guides; snaps within 1 px when centers nearly align.
  void dragBy(
    String id,
    Offset delta,
    Size canvas, {
    Map<String, Rect>? measuredRects,
  }) {
    if (canvas.width <= 0 || canvas.height <= 0) return;
    final placed = _draft.byId(id);
    if (placed == null) return;

    var totalDelta = delta;
    if (measuredRects != null && measuredRects.containsKey(id)) {
      final result = AlignmentGuideEngine.evaluate(
        draggedId: id,
        dragDelta: delta,
        measuredRects: measuredRects,
        canvas: canvas,
      );
      totalDelta = delta + result.snapDeltaPx;
      _activeGuides = result.guides;
    } else {
      _activeGuides = const [];
    }

    final next = placed.config.copyWith(
      xPercentage:
          placed.config.xPercentage + totalDelta.dx / canvas.width,
      yPercentage:
          placed.config.yPercentage + totalDelta.dy / canvas.height,
    );
    _draft = _draft.copyWithControl(id, placed.copyWith(config: next));
    _selectedId = id;
    _isDragging = true;

    notifyListeners();
  }

  void endDrag() {
    _activeGuides = const [];
    if (_snapToGrid && _selectedId != null) {
      final placed = _draft.byId(_selectedId!);
      if (placed != null) {
        final next = placed.config.copyWith(
          xPercentage: _snap(placed.config.xPercentage, _horizontalSegments),
          yPercentage: _snap(placed.config.yPercentage, _verticalSegments),
        );
        _draft = _draft.copyWithControl(
          _selectedId!,
          placed.copyWith(config: next),
        );
      }
    }
    _isDragging = false;
    notifyListeners();
  }

  /// Add a new control of the given [type] to the canvas.
  /// Places it at the center with a default size.
  void addControl(PlayerControlType type) {
    final id = '${type.id}_${_randomId()}';
    final defaultConfig = ControlConfig(
      xPercentage: 0.5,
      yPercentage: 0.5,
      sizePercentage: type.isProgressBar ? 0.07 : 0.08,
      widthPercentage: type.isTimelineBar ? 1.0 : 0.85,
      timelineOptions: switch (type) {
        PlayerControlType.timeline => switch (_draft.skin) {
            ControlSkinStyle.flat => TimelineChromeOptions.flat(),
            ControlSkinStyle.neumorphic => TimelineChromeOptions.neumorphic(),
            ControlSkinStyle.glass => TimelineChromeOptions.glass(),
          },
        PlayerControlType.timelineGlassInline => TimelineChromeOptions.glass(),
        PlayerControlType.timelineEmby => TimelineChromeOptions.emby(),
        _ => null,
      },
    );
    final placed = PlacedControl(id: id, type: type, config: defaultConfig);
    _draft = _draft.withAddedControl(placed);
    _selectedId = id;
    notifyListeners();
  }

  /// Update embedded timeline button visibility for the selected timeline bar.
  void setSelectedTimelineOptions(TimelineChromeOptions options) {
    final id = _selectedId;
    if (id == null) return;
    final placed = _draft.byId(id);
    if (placed == null || !placed.type.isTimelineBar) return;

    _draft = _draft.copyWithControl(
      id,
      placed.copyWith(
        config: placed.config.copyWith(timelineOptions: options),
      ),
    );
    notifyListeners();
  }

  /// Remove the placed control with the given [id].
  void removeControl(String id) {
    _draft = _draft.withoutControl(id);
    if (_selectedId == id) _selectedId = null;
    notifyListeners();
  }

  /// Update the relative size of the currently selected control.
  /// If the selected control is [rewind] or [forward], the other one is
  /// automatically kept in sync so both buttons always share the same size.
  void setSelectedSizePercentage(double sizePercentage) {
    final id = _selectedId;
    if (id == null) return;
    final placed = _draft.byId(id);
    if (placed == null) return;

    _draft = _draft.copyWithControl(
      id,
      placed.copyWith(
        config: placed.config.copyWith(sizePercentage: sizePercentage),
      ),
    );

    // Keep rewind and forward sizes identical.
    final syncTarget = switch (placed.type) {
      PlayerControlType.rewind => PlayerControlType.forward,
      PlayerControlType.forward => PlayerControlType.rewind,
      _ => null,
    };
    if (syncTarget != null) {
      final syncPlaced = _draft.controls
          .cast<PlacedControl?>()
          .firstWhere((c) => c?.type == syncTarget, orElse: () => null);
      if (syncPlaced != null) {
        _draft = _draft.copyWithControl(
          syncPlaced.id,
          syncPlaced.copyWith(
            config: syncPlaced.config.copyWith(sizePercentage: sizePercentage),
          ),
        );
      }
    }

    notifyListeners();
  }

  /// Update the relative width of the currently selected control
  /// (progress bar only, 0.1 -> 1.0).
  void setSelectedWidthPercentage(double widthPercentage) {
    final id = _selectedId;
    if (id == null) return;
    final placed = _draft.byId(id);
    if (placed == null) return;
    _draft = _draft.copyWithControl(
      id,
      placed.copyWith(
        config: placed.config.copyWith(widthPercentage: widthPercentage),
      ),
    );
    notifyListeners();
  }

  /// Restore the standard default layout in the draft (not yet persisted).
  void resetDraft() {
    _draft = PlayerLayoutConfig.standard();
    _selectedId = null;
    notifyListeners();
  }

  /// Replace the draft with a persisted layout (e.g. after async storage load).
  void loadDraft(PlayerLayoutConfig config) {
    _draft = config;
    _selectedId = null;
    _isDragging = false;
    _activeGuides = const [];
    notifyListeners();
  }

  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random();
    return List.generate(6, (_) => chars[rand.nextInt(chars.length)]).join();
  }
}
