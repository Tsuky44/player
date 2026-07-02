import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';

/// Relative size boundaries for controls (fraction of shortest screen side).
const double kMinSizePct = 0.03;
const double kMaxSizePct = 0.12;

/// Minimum width percentage so the progress bar never disappears.
const double kMinProgressWidthPct = 0.1;

/// Glass styling bounds for the modular control chrome.
const double kMinBlurSigma = 0.0;
const double kMaxBlurSigma = 30.0;
const double kDefaultBlurSigma = 8.0;

const double kMinGlassOpacity = 0.0;
const double kMaxGlassOpacity = 0.4;
const double kDefaultGlassOpacity = 0.07;

/// When false, controls use a lightweight flat glass (blur + tint only).
const bool kDefaultLiquidGlass = false;

/// The set of button variants available in the Player Studio shop.
enum PlayerControlType {
  back,
  mediaTitle,
  mediaLogo,
  rewind,
  playPause,
  forward,
  progressBar,
  timeline,
  skipPrevious,
  skipNext,
  volumeUp,
  volumeDown,
  mute,
  volumeSlider,
  fullscreen,
  settings,
  subtitles,
}

extension PlayerControlTypeX on PlayerControlType {
  /// Stable string id used as JSON key (never change once persisted).
  String get id => name;

  String get label {
    switch (this) {
      case PlayerControlType.back:
        return 'Retour';
      case PlayerControlType.mediaTitle:
        return 'Titre du média';
      case PlayerControlType.mediaLogo:
        return 'Logo du média';
      case PlayerControlType.rewind:
        return 'Reculer 10s';
      case PlayerControlType.playPause:
        return 'Lecture / Pause';
      case PlayerControlType.forward:
        return 'Avancer 10s';
      case PlayerControlType.progressBar:
        return 'Barre de progression';
      case PlayerControlType.timeline:
        return 'Barre de timeline';
      case PlayerControlType.skipPrevious:
        return 'Épisode précédent';
      case PlayerControlType.skipNext:
        return 'Épisode suivant';
      case PlayerControlType.volumeUp:
        return 'Volume +';
      case PlayerControlType.volumeDown:
        return 'Volume -';
      case PlayerControlType.mute:
        return 'Muet';
      case PlayerControlType.volumeSlider:
        return 'Curseur de volume';
      case PlayerControlType.fullscreen:
        return 'Plein écran';
      case PlayerControlType.settings:
        return 'Paramètres';
      case PlayerControlType.subtitles:
        return 'Sous-titres';
    }
  }

  IconData get icon {
    switch (this) {
      case PlayerControlType.back:
        return Icons.arrow_back;
      case PlayerControlType.mediaTitle:
        return Icons.title;
      case PlayerControlType.mediaLogo:
        return Icons.branding_watermark_outlined;
      case PlayerControlType.rewind:
        return Icons.replay_10;
      case PlayerControlType.playPause:
        return Icons.play_arrow;
      case PlayerControlType.forward:
        return Icons.forward_10;
      case PlayerControlType.progressBar:
        return Icons.linear_scale;
      case PlayerControlType.timeline:
        return Icons.timeline;
      case PlayerControlType.skipPrevious:
        return Icons.skip_previous;
      case PlayerControlType.skipNext:
        return Icons.skip_next;
      case PlayerControlType.volumeUp:
        return Icons.volume_up;
      case PlayerControlType.volumeDown:
        return Icons.volume_down;
      case PlayerControlType.mute:
        return Icons.volume_off;
      case PlayerControlType.volumeSlider:
        return Icons.volume_down;
      case PlayerControlType.fullscreen:
        return Icons.fullscreen;
      case PlayerControlType.settings:
        return Icons.settings;
      case PlayerControlType.subtitles:
        return Icons.subtitles;
    }
  }

  /// Whether this control should only appear once in the layout.
  bool get isUnique =>
      this == PlayerControlType.progressBar ||
      this == PlayerControlType.timeline ||
      this == PlayerControlType.mediaTitle ||
      this == PlayerControlType.mediaLogo ||
      this == PlayerControlType.volumeSlider;

  /// Whether this control is a progress/timeline bar (has width slider).
  bool get isProgressBar =>
      this == PlayerControlType.progressBar || this == PlayerControlType.timeline;

  static PlayerControlType fromId(String value) {
    return PlayerControlType.values.firstWhere(
      (e) => e.id == value,
      orElse: () => PlayerControlType.playPause,
    );
  }
}

/// Position + size of a single control, stored as RELATIVE values so the
/// layout scales identically across phones, tablets, desktop and TV.
///
/// [xPercentage]/[yPercentage] describe the CENTER of the control (0.0 -> 1.0).
class ControlConfig {
  final double xPercentage;
  final double yPercentage;
  /// Relative size as a fraction of the shortest screen side
  /// (0.03 -> 0.12). Applies to icon diameter and progress bar height.
  final double sizePercentage;

  /// Relative width for the progress bar as a fraction of screen width
  /// (0.0 -> 1.0). Ignored for icon controls.
  final double widthPercentage;

  const ControlConfig({
    required this.xPercentage,
    required this.yPercentage,
    required this.sizePercentage,
    this.widthPercentage = 0.85,
  });

  ControlConfig copyWith({
    double? xPercentage,
    double? yPercentage,
    double? sizePercentage,
    double? widthPercentage,
  }) {
    return ControlConfig(
      xPercentage: (xPercentage ?? this.xPercentage).clamp(0.0, 1.0),
      yPercentage: (yPercentage ?? this.yPercentage).clamp(0.0, 1.0),
      sizePercentage: (sizePercentage ?? this.sizePercentage)
          .clamp(kMinSizePct, kMaxSizePct),
      widthPercentage: (widthPercentage ?? this.widthPercentage)
          .clamp(kMinProgressWidthPct, 1.0),
    );
  }

  Map<String, dynamic> toJson() => {
        'x_percentage': xPercentage,
        'y_percentage': yPercentage,
        'size_percentage': sizePercentage,
        'width_percentage': widthPercentage,
      };

  factory ControlConfig.fromJson(Map<String, dynamic> json) {
    return ControlConfig(
      xPercentage: ((json['x_percentage'] as num?)?.toDouble() ?? 0.5)
          .clamp(0.0, 1.0),
      yPercentage: ((json['y_percentage'] as num?)?.toDouble() ?? 0.5)
          .clamp(0.0, 1.0),
      sizePercentage: ((json['size_percentage'] as num?)?.toDouble() ?? 0.08)
          .clamp(kMinSizePct, kMaxSizePct),
      widthPercentage: ((json['width_percentage'] as num?)?.toDouble() ?? 0.85)
          .clamp(kMinProgressWidthPct, 1.0),
    );
  }
}

/// A single placed control on the canvas, identified by a unique [id]
/// so multiple instances of the same [type] can coexist.
class PlacedControl {
  final String id;
  final PlayerControlType type;
  final ControlConfig config;

  const PlacedControl({
    required this.id,
    required this.type,
    required this.config,
  });

  PlacedControl copyWith({
    String? id,
    PlayerControlType? type,
    ControlConfig? config,
  }) {
    return PlacedControl(
      id: id ?? this.id,
      type: type ?? this.type,
      config: config ?? this.config,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.id,
        'config': config.toJson(),
      };

  factory PlacedControl.fromJson(Map<String, dynamic> json) {
    return PlacedControl(
      id: (json['id'] as String?) ?? '',
      type: PlayerControlTypeX.fromId(json['type'] as String? ?? 'playPause'),
      config: ControlConfig.fromJson(json['config'] as Map<String, dynamic>),
    );
  }
}

/// Full modular layout for the player overlay.
class PlayerLayoutConfig {
  final List<PlacedControl> controls;

  /// Blur sigma applied to the frosted control chrome (0 = no blur).
  final double blurIntensity;

  /// Background opacity of the frosted control chrome (0 = fully transparent).
  final double glassOpacity;

  /// Apple-style liquid glass (saturation boost, rim, sheen). Off = flat glass.
  final bool liquidGlass;

  const PlayerLayoutConfig({
    required this.controls,
    this.blurIntensity = kDefaultBlurSigma,
    this.glassOpacity = kDefaultGlassOpacity,
    this.liquidGlass = kDefaultLiquidGlass,
  });

  PlayerLayoutConfig copyWith({
    List<PlacedControl>? controls,
    double? blurIntensity,
    double? glassOpacity,
    bool? liquidGlass,
  }) {
    return PlayerLayoutConfig(
      controls: controls ?? this.controls,
      blurIntensity: (blurIntensity ?? this.blurIntensity)
          .clamp(kMinBlurSigma, kMaxBlurSigma),
      glassOpacity: (glassOpacity ?? this.glassOpacity)
          .clamp(kMinGlassOpacity, kMaxGlassOpacity),
      liquidGlass: liquidGlass ?? this.liquidGlass,
    );
  }

  /// Default layout that mirrors the standard player look.
  factory PlayerLayoutConfig.standard() {
    return const PlayerLayoutConfig(controls: [
      PlacedControl(
        id: 'rewind',
        type: PlayerControlType.rewind,
        config: ControlConfig(
            xPercentage: 0.42, yPercentage: 0.86, sizePercentage: 0.08),
      ),
      PlacedControl(
        id: 'playPause',
        type: PlayerControlType.playPause,
        config: ControlConfig(
            xPercentage: 0.5, yPercentage: 0.86, sizePercentage: 0.12),
      ),
      PlacedControl(
        id: 'forward',
        type: PlayerControlType.forward,
        config: ControlConfig(
            xPercentage: 0.58, yPercentage: 0.86, sizePercentage: 0.08),
      ),
      PlacedControl(
        id: 'progressBar',
        type: PlayerControlType.progressBar,
        config: ControlConfig(
            xPercentage: 0.5,
            yPercentage: 0.74,
            sizePercentage: 0.07,
            widthPercentage: 0.85),
      ),
    ]);
  }

  /// Find a placed control by its unique [id].
  PlacedControl? byId(String id) {
    for (final c in controls) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Replace a placed control by [id].
  PlayerLayoutConfig copyWithControl(String id, PlacedControl placed) {
    return copyWith(
      controls: [
        for (final c in controls)
          if (c.id == id) placed else c,
      ],
    );
  }

  /// Remove a placed control by [id].
  PlayerLayoutConfig withoutControl(String id) {
    return copyWith(
      controls: controls.where((c) => c.id != id).toList(),
    );
  }

  /// Append a new placed control.
  PlayerLayoutConfig withAddedControl(PlacedControl placed) {
    return copyWith(controls: [...controls, placed]);
  }

  Map<String, dynamic> toJson() => {
        'version': 2,
        'blur_intensity': blurIntensity,
        'glass_opacity': glassOpacity,
        'liquid_glass': liquidGlass,
        'controls': controls.map((c) => c.toJson()).toList(),
      };

  factory PlayerLayoutConfig.fromJson(Map<String, dynamic> json) {
    final blur = ((json['blur_intensity'] as num?)?.toDouble() ??
            kDefaultBlurSigma)
        .clamp(kMinBlurSigma, kMaxBlurSigma);
    final opacity = ((json['glass_opacity'] as num?)?.toDouble() ??
            kDefaultGlassOpacity)
        .clamp(kMinGlassOpacity, kMaxGlassOpacity);
    final liquid = json['liquid_glass'] as bool? ?? kDefaultLiquidGlass;

    // New format (v2)
    if (json['controls'] is List) {
      final list = (json['controls'] as List).cast<Map<String, dynamic>>();
      return PlayerLayoutConfig(
        controls: list.map(PlacedControl.fromJson).toList(),
        blurIntensity: blur,
        glassOpacity: opacity,
        liquidGlass: liquid,
      );
    }
    // Migrate from old v1 format (Map<typeId, config>)
    return _migrateFromV1(json).copyWith(
      blurIntensity: blur,
      glassOpacity: opacity,
      liquidGlass: liquid,
    );
  }

  static PlayerLayoutConfig _migrateFromV1(Map<String, dynamic> json) {
    final controls = <PlacedControl>[];
    for (final type in PlayerControlType.values) {
      final raw = json[type.id];
      if (raw is Map<String, dynamic>) {
        controls.add(PlacedControl(
          id: type.id,
          type: type,
          config: ControlConfig.fromJson(raw),
        ));
      }
    }
    if (controls.isEmpty) return PlayerLayoutConfig.standard();
    return PlayerLayoutConfig(controls: controls);
  }

  String encode() => jsonEncode(toJson());

  factory PlayerLayoutConfig.decode(String raw) {
    return PlayerLayoutConfig.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }
}

/// Default subtitle padding when player controls are hidden.
const kSubtitlePaddingBase = EdgeInsets.fromLTRB(16, 0, 16, 24);

/// Distance from the screen bottom to the top of the progress bar (standard HUD).
const kStandardHudTimelineTopInset = 118.0;

const kSubtitleGapAboveTimeline = 12.0;

/// Computes subtitle bottom padding so text sits above visible player controls.
class SubtitlePaddingCalculator {
  static EdgeInsets resolve({
    required bool controlsVisible,
    required bool useModularLayout,
    required PlayerLayoutConfig modularConfig,
    required Size screenSize,
    double? measuredTimelineTopDy,
  }) {
    if (!controlsVisible) return kSubtitlePaddingBase;

    if (measuredTimelineTopDy != null) {
      return fromTimelineTop(measuredTimelineTopDy, screenSize);
    }

    final bottomInset = useModularLayout
        ? modularConfig.subtitleInsetAboveTimeline(screenSize)
        : kStandardHudTimelineTopInset;

    return EdgeInsets.fromLTRB(
      16,
      0,
      16,
      bottomInset + kSubtitleGapAboveTimeline,
    );
  }

  /// Builds padding from the timeline/progress bar top edge (screen coordinates).
  static EdgeInsets fromTimelineTop(double timelineTopDy, Size screenSize) {
    final bottomInset = (screenSize.height - timelineTopDy)
        .clamp(kSubtitlePaddingBase.bottom, screenSize.height * 0.45);
    return EdgeInsets.fromLTRB(
      16,
      0,
      16,
      bottomInset + kSubtitleGapAboveTimeline,
    );
  }
}

extension PlayerLayoutSubtitleLayout on PlayerLayoutConfig {
  /// Bottom padding target: just above the timeline / progress bar (YouTube-style).
  double subtitleInsetAboveTimeline(Size screenSize) {
    PlacedControl? bottomTimeline;
    for (final placed in controls) {
      if (!placed.type.isProgressBar) continue;
      if (bottomTimeline == null ||
          placed.config.yPercentage > bottomTimeline.config.yPercentage) {
        bottomTimeline = placed;
      }
    }

    if (bottomTimeline != null) {
      return _controlTopInset(bottomTimeline, screenSize);
    }

    // No timeline placed: use the top edge of the bottom control band only.
    var clusterTop = 0.0;
    for (final placed in controls) {
      if (placed.config.yPercentage < 0.55) continue;
      final top = _controlTopY(placed, screenSize);
      clusterTop = max(clusterTop, top);
    }
    if (clusterTop > 0) {
      return screenSize.height - clusterTop;
    }

    return kStandardHudTimelineTopInset;
  }

  double _controlTopY(PlacedControl placed, Size screenSize) {
    final size = estimatePlacedControlSize(placed, screenSize);
    final centerY = placed.config.yPercentage * screenSize.height;
    return centerY - size.height / 2;
  }

  double _controlTopInset(PlacedControl placed, Size screenSize) {
    return screenSize.height - _controlTopY(placed, screenSize);
  }

  /// Mirrors [ControlChrome] sizing so subtitle lift matches the real layout.
  Size estimatePlacedControlSize(PlacedControl placed, Size screenSize) {
    final config = placed.config;
    final pixelSize = screenSize.shortestSide * config.sizePercentage;

    switch (placed.type) {
      case PlayerControlType.progressBar:
        final barHeight = (pixelSize * 0.4).clamp(10.0, 32.0);
        final verticalPadding = (barHeight / 2).clamp(8.0, 16.0) * 2;
        return Size(
          screenSize.width * config.widthPercentage.clamp(0.1, 1.0),
          barHeight + verticalPadding,
        );
      case PlayerControlType.timeline:
        final height = (pixelSize * 0.5).clamp(14.0, 40.0);
        return Size(
          screenSize.width * config.widthPercentage.clamp(0.3, 1.0),
          height,
        );
      case PlayerControlType.mediaTitle:
        final height = (pixelSize * 0.8).clamp(24.0, 48.0);
        return Size(screenSize.width * 0.5, height);
      case PlayerControlType.mediaLogo:
        final height = (pixelSize * 1.4).clamp(36.0, 100.0);
        return Size(screenSize.width * 0.38, height);
      case PlayerControlType.volumeSlider:
        final height = (pixelSize * 0.5).clamp(16.0, 40.0);
        return Size(
          screenSize.width * config.widthPercentage.clamp(0.05, 0.5),
          height,
        );
      default:
        final diameter = pixelSize * 1.4;
        return Size(diameter, diameter);
    }
  }
}
