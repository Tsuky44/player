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

/// Accent colour swatches offered for the Flat skin (restricted palette,
/// no free colour picker).
const List<Color> kFlatAccentPalette = [
  Color(0xFF0A84FF), // blue (matches the glass accent)
  Color(0xFFFF453A), // red
  Color(0xFFFF9F0A), // orange
  Color(0xFF30D158), // green
  Color(0xFFBF5AF2), // purple
  Color(0xFFFFD60A), // yellow
];

const Color kDefaultFlatAccentColor = Color(0xFF0A84FF);
const FlatElevation kDefaultFlatElevation = FlatElevation.light;

/// Shadow depth for the Neumorphic skin (0 = flat, 1 = deeply extruded).
const double kMinNeumorphicIntensity = 0.0;
const double kMaxNeumorphicIntensity = 1.0;
const double kDefaultNeumorphicIntensity = 0.5;

/// Circle diameter = icon px × this (was 1.4 — too puffy on large canvases).
const double kControlChromePaddingFactor = 1.22;

/// Converts layout [sizePercentage] into icon pixels with phone / desktop / TV
/// clamps so controls stay tappable without becoming dinner plates.
///
/// Uses [Size.longestSide] as well as shortest so landscape desktop windows
/// (e.g. 1280×720) are not treated like oversized phones.
double modularControlPixelSize(
  Size canvasSize,
  double sizePercentage, {
  double emphasis = 1.0,
}) {
  final raw = canvasSize.shortestSide * sizePercentage * emphasis;
  final short = canvasSize.shortestSide;
  final long = canvasSize.longestSide;
  late final double floor;
  late final double ceiling;
  if (long >= 1600 || short >= 1000) {
    // Large desktop / TV (10-foot)
    floor = 40;
    ceiling = 52;
  } else if (long >= 900) {
    // Desktop / tablet player window (incl. 1280×720 landscape)
    floor = 34;
    ceiling = 44;
  } else if (short < 480) {
    // Phone portrait / compact
    floor = 36;
    ceiling = 50;
  } else {
    // Phone landscape / small tablet
    floor = 34;
    ceiling = 46;
  }
  final maxAllowed = emphasis > 1.0 ? ceiling * 1.12 : ceiling;
  return raw.clamp(floor, maxAllowed);
}

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
  timelineEmby,
  timelineGlassInline,
  skipPrevious,
  skipNext,
  volumeUp,
  volumeDown,
  mute,
  volumeSlider,
  fullscreen,
  settings,
  subtitles,
  upNext,
  upNextEmby,
  // Pack Cinéma Essentiel (Player Studio shop)
  skipIntro,
  playbackSpeed,
  aspectFit,
  audioTracks,
  chapters,
  timeRemaining,
  rewind30,
  forward30,
  // Emby template extras
  episodeTitleBlock,
  chaptersEmby,
  mediaInfo,
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
        return 'Timeline verre';
      case PlayerControlType.timelineEmby:
        return 'Timeline Emby';
      case PlayerControlType.timelineGlassInline:
        return 'Timeline verre fin';
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
      case PlayerControlType.upNext:
        return 'À suivre';
      case PlayerControlType.upNextEmby:
        return 'À suivre Emby';
      case PlayerControlType.skipIntro:
        return 'Passer l\'intro';
      case PlayerControlType.playbackSpeed:
        return 'Vitesse';
      case PlayerControlType.aspectFit:
        return 'Affichage';
      case PlayerControlType.audioTracks:
        return 'Piste audio';
      case PlayerControlType.chapters:
        return 'Chapitres';
      case PlayerControlType.timeRemaining:
        return 'Temps restant';
      case PlayerControlType.rewind30:
        return 'Reculer 30s';
      case PlayerControlType.forward30:
        return 'Avancer 30s';
      case PlayerControlType.episodeTitleBlock:
        return 'Bloc titre (Emby)';
      case PlayerControlType.chaptersEmby:
        return 'Chapitres (lien texte)';
      case PlayerControlType.mediaInfo:
        return 'Infos média';
    }
  }

  IconData get icon {
    switch (this) {
      case PlayerControlType.back:
        return Icons.arrow_back_rounded;
      case PlayerControlType.mediaTitle:
        return Icons.title_rounded;
      case PlayerControlType.mediaLogo:
        return Icons.branding_watermark_outlined;
      case PlayerControlType.rewind:
        return Icons.replay_10_rounded;
      case PlayerControlType.playPause:
        return Icons.play_arrow_rounded;
      case PlayerControlType.forward:
        return Icons.forward_10_rounded;
      case PlayerControlType.progressBar:
        return Icons.linear_scale_rounded;
      case PlayerControlType.timeline:
        return Icons.timeline_rounded;
      case PlayerControlType.timelineEmby:
        return Icons.view_timeline_outlined;
      case PlayerControlType.timelineGlassInline:
        return Icons.view_agenda_outlined;
      case PlayerControlType.skipPrevious:
        return Icons.skip_previous_rounded;
      case PlayerControlType.skipNext:
        return Icons.skip_next_rounded;
      case PlayerControlType.volumeUp:
        return Icons.volume_up_rounded;
      case PlayerControlType.volumeDown:
        return Icons.volume_down_rounded;
      case PlayerControlType.mute:
        return Icons.volume_off_rounded;
      case PlayerControlType.volumeSlider:
        return Icons.volume_down_rounded;
      case PlayerControlType.fullscreen:
        return Icons.fullscreen_rounded;
      case PlayerControlType.settings:
        return Icons.settings_rounded;
      case PlayerControlType.subtitles:
        return Icons.subtitles_outlined;
      case PlayerControlType.upNext:
        return Icons.playlist_play_rounded;
      case PlayerControlType.upNextEmby:
        return Icons.view_list_rounded;
      case PlayerControlType.skipIntro:
        return Icons.fast_forward_rounded;
      case PlayerControlType.playbackSpeed:
        return Icons.speed_rounded;
      case PlayerControlType.aspectFit:
        return Icons.aspect_ratio_rounded;
      case PlayerControlType.audioTracks:
        return Icons.audiotrack_rounded;
      case PlayerControlType.chapters:
        return Icons.list_alt_rounded;
      case PlayerControlType.timeRemaining:
        return Icons.timer_outlined;
      case PlayerControlType.rewind30:
        return Icons.replay_30_rounded;
      case PlayerControlType.forward30:
        return Icons.forward_30_rounded;
      case PlayerControlType.episodeTitleBlock:
        return Icons.subtitles_outlined;
      case PlayerControlType.chaptersEmby:
        return Icons.list_alt_rounded;
      case PlayerControlType.mediaInfo:
        return Icons.info_outline_rounded;
    }
  }

  /// Timeline bar variant (glass pill or Emby minimal overlay).
  bool get isTimelineBar =>
      this == PlayerControlType.timeline ||
      this == PlayerControlType.timelineEmby ||
      this == PlayerControlType.timelineGlassInline;

  /// Whether this control should only appear once in the layout.
  bool get isUnique =>
      this == PlayerControlType.progressBar ||
      isTimelineBar ||
      this == PlayerControlType.mediaTitle ||
      this == PlayerControlType.mediaLogo ||
      this == PlayerControlType.volumeSlider ||
      this == PlayerControlType.upNext ||
      this == PlayerControlType.upNextEmby ||
      this == PlayerControlType.skipIntro ||
      this == PlayerControlType.playbackSpeed ||
      this == PlayerControlType.aspectFit ||
      this == PlayerControlType.audioTracks ||
      this == PlayerControlType.chapters ||
      this == PlayerControlType.timeRemaining ||
      this == PlayerControlType.episodeTitleBlock ||
      this == PlayerControlType.chaptersEmby ||
      this == PlayerControlType.mediaInfo;

  /// Pack Cinéma Essentiel — new shop section.
  bool get isCinemaPack =>
      this == PlayerControlType.skipIntro ||
      this == PlayerControlType.playbackSpeed ||
      this == PlayerControlType.aspectFit ||
      this == PlayerControlType.audioTracks ||
      this == PlayerControlType.chapters ||
      this == PlayerControlType.timeRemaining ||
      this == PlayerControlType.rewind30 ||
      this == PlayerControlType.forward30;

  /// Whether this control is a progress/timeline bar (has width slider).
  bool get isProgressBar =>
      this == PlayerControlType.progressBar || isTimelineBar;

  static PlayerControlType fromId(String value) {
    return PlayerControlType.values.firstWhere(
      (e) => e.id == value,
      orElse: () => PlayerControlType.playPause,
    );
  }
}

/// A hand-written, non-editable player chrome.
///
/// A preset carrying one of these renders that chrome verbatim instead of the
/// modular layer: [PlayerLayoutConfig.controls], [PlayerLayoutConfig.skin] and
/// every other appearance field are ignored. Player Studio shows such a preset
/// as a frozen preview — there is nothing in it to move.
enum FixedChromeId {
  /// Clone of the Emby web player chrome.
  emby;

  String get id => name;

  String get label => switch (this) {
        FixedChromeId.emby => 'Emby',
      };

  /// Unknown ids decode to null so a preset written by a newer client
  /// degrades to its modular layout instead of failing to load.
  static FixedChromeId? fromId(String? value) {
    return switch (value) {
      'emby' => FixedChromeId.emby,
      _ => null,
    };
  }
}

/// Visual language applied to every control's chrome for a given preset.
///
/// One skin per preset (not per control) — chosen alongside a layout so the
/// whole playeur reads as a single, coherent design.
enum ControlSkinStyle {
  /// Frosted, translucent chrome (the original — and only — look).
  glass,

  /// Opaque flat surfaces, no blur, accent colour + elevation.
  flat,

  /// Soft extruded surfaces with dual light/dark shadows, no blur.
  neumorphic;

  String get id => name;

  String get label => switch (this) {
        ControlSkinStyle.glass => 'Verre',
        ControlSkinStyle.flat => 'Net',
        ControlSkinStyle.neumorphic => 'Doux',
      };

  static ControlSkinStyle fromId(String? value) {
    return switch (value) {
      'flat' => ControlSkinStyle.flat,
      'neumorphic' => ControlSkinStyle.neumorphic,
      _ => ControlSkinStyle.glass,
    };
  }
}

/// Drop-shadow strength for the Flat skin.
enum FlatElevation {
  none,
  light,
  marked;

  String get id => name;

  String get label => switch (this) {
        FlatElevation.none => 'Aucune',
        FlatElevation.light => 'Légère',
        FlatElevation.marked => 'Marquée',
      };

  static FlatElevation fromId(String? value) {
    return switch (value) {
      'none' => FlatElevation.none,
      'marked' => FlatElevation.marked,
      _ => FlatElevation.light,
    };
  }
}

/// Visual presentation of the [PlayerControlType.timeline] control.
enum TimelineVisualStyle {
  /// Frosted pill with accent-colour progress (default legacy look).
  glass,

  /// Minimal Emby-style overlay: no background, thin white bar, flat icons.
  emby,

  /// Opaque flat pill matching the Flat control skin.
  flat,

  /// Soft extruded pill matching the Neumorphic control skin.
  neumorphic;

  String get id => name;

  String get label => switch (this) {
        TimelineVisualStyle.glass => 'Verre',
        TimelineVisualStyle.emby => 'Emby',
        TimelineVisualStyle.flat => 'Net',
        TimelineVisualStyle.neumorphic => 'Doux',
      };

  static TimelineVisualStyle fromId(String? value) {
    return switch (value) {
      'emby' => TimelineVisualStyle.emby,
      'flat' => TimelineVisualStyle.flat,
      'neumorphic' => TimelineVisualStyle.neumorphic,
      _ => TimelineVisualStyle.glass,
    };
  }
}

/// Visibility flags for buttons embedded in the [PlayerControlType.timeline] bar.
class TimelineChromeOptions {
  final TimelineVisualStyle visualStyle;
  final bool showSkipPrevious;
  final bool showRewind;
  final bool showPlayPause;
  final bool showForward;
  final bool showSkipNext;
  final bool showSettings;
  final bool showSubtitles;
  final bool showFullscreen;
  final bool showUpNext;

  const TimelineChromeOptions({
    this.visualStyle = TimelineVisualStyle.glass,
    this.showSkipPrevious = false,
    this.showRewind = false,
    this.showPlayPause = false,
    this.showForward = false,
    this.showSkipNext = false,
    this.showSettings = false,
    this.showSubtitles = false,
    this.showFullscreen = true,
    this.showUpNext = false,
  });

  /// Matches layouts saved before embedded timeline buttons existed.
  factory TimelineChromeOptions.legacy() =>
      const TimelineChromeOptions(showFullscreen: true);

  /// Glass pill defaults for [PlayerControlType.timeline].
  factory TimelineChromeOptions.glass() => const TimelineChromeOptions(
        visualStyle: TimelineVisualStyle.glass,
        showSkipPrevious: true,
        showRewind: true,
        showPlayPause: true,
        showForward: true,
        showSkipNext: true,
        showSettings: true,
        showSubtitles: true,
        showFullscreen: true,
      );

  /// Emby-style defaults for [PlayerControlType.timelineEmby].
  factory TimelineChromeOptions.emby() => const TimelineChromeOptions(
        visualStyle: TimelineVisualStyle.emby,
        showSkipPrevious: true,
        showRewind: true,
        showPlayPause: true,
        showForward: true,
        showSkipNext: true,
        showSettings: true,
        showSubtitles: true,
        showFullscreen: true,
      );

  /// Flat-skin defaults for [PlayerControlType.timeline] under the Flat skin.
  factory TimelineChromeOptions.flat() => const TimelineChromeOptions(
        visualStyle: TimelineVisualStyle.flat,
        showSkipPrevious: true,
        showRewind: true,
        showPlayPause: true,
        showForward: true,
        showSkipNext: true,
        showSettings: true,
        showSubtitles: true,
        showFullscreen: true,
      );

  /// Neumorphic-skin defaults for [PlayerControlType.timeline].
  factory TimelineChromeOptions.neumorphic() => const TimelineChromeOptions(
        visualStyle: TimelineVisualStyle.neumorphic,
        showSkipPrevious: true,
        showRewind: true,
        showPlayPause: true,
        showForward: true,
        showSkipNext: true,
        showSettings: true,
        showSubtitles: true,
        showFullscreen: true,
      );

  /// Type-aware defaults used when parsing sparse saved JSON and at runtime.
  static TimelineChromeOptions defaultsFor(PlayerControlType type) {
    return switch (type) {
      PlayerControlType.timeline => TimelineChromeOptions.glass(),
      PlayerControlType.timelineGlassInline => TimelineChromeOptions.glass(),
      PlayerControlType.timelineEmby => TimelineChromeOptions.emby(),
      _ => TimelineChromeOptions.legacy(),
    };
  }

  bool get hasLeftCluster =>
      showSkipPrevious ||
      showRewind ||
      showPlayPause ||
      showForward ||
      showSkipNext;

  bool get hasRightCluster =>
      showSettings || showSubtitles || showFullscreen || showUpNext;

  /// Bottom row: transport + settings + subtitles (not fullscreen).
  bool get hasBottomRow =>
      hasLeftCluster || showSettings || showSubtitles || showUpNext;

  bool get hasUtilityRow =>
      showSettings || showSubtitles || showFullscreen || showUpNext;

  TimelineChromeOptions copyWith({
    TimelineVisualStyle? visualStyle,
    bool? showSkipPrevious,
    bool? showRewind,
    bool? showPlayPause,
    bool? showForward,
    bool? showSkipNext,
    bool? showSettings,
    bool? showSubtitles,
    bool? showFullscreen,
    bool? showUpNext,
  }) {
    return TimelineChromeOptions(
      visualStyle: visualStyle ?? this.visualStyle,
      showSkipPrevious: showSkipPrevious ?? this.showSkipPrevious,
      showRewind: showRewind ?? this.showRewind,
      showPlayPause: showPlayPause ?? this.showPlayPause,
      showForward: showForward ?? this.showForward,
      showSkipNext: showSkipNext ?? this.showSkipNext,
      showSettings: showSettings ?? this.showSettings,
      showSubtitles: showSubtitles ?? this.showSubtitles,
      showFullscreen: showFullscreen ?? this.showFullscreen,
      showUpNext: showUpNext ?? this.showUpNext,
    );
  }

  Map<String, dynamic> toJson() => {
        'visual_style': visualStyle.id,
        'show_skip_previous': showSkipPrevious,
        'show_rewind': showRewind,
        'show_play_pause': showPlayPause,
        'show_forward': showForward,
        'show_skip_next': showSkipNext,
        'show_settings': showSettings,
        'show_subtitles': showSubtitles,
        'show_fullscreen': showFullscreen,
        'show_up_next': showUpNext,
      };

  factory TimelineChromeOptions.fromJson(
    Map<String, dynamic>? json, {
    TimelineChromeOptions? defaults,
  }) {
    final base = defaults ?? TimelineChromeOptions.legacy();
    if (json == null) return base;
    return base.copyWith(
      visualStyle: json.containsKey('visual_style')
          ? TimelineVisualStyle.fromId(json['visual_style'] as String?)
          : null,
      showSkipPrevious: json.containsKey('show_skip_previous')
          ? json['show_skip_previous'] as bool
          : null,
      showRewind:
          json.containsKey('show_rewind') ? json['show_rewind'] as bool : null,
      showPlayPause: json.containsKey('show_play_pause')
          ? json['show_play_pause'] as bool
          : null,
      showForward:
          json.containsKey('show_forward') ? json['show_forward'] as bool : null,
      showSkipNext: json.containsKey('show_skip_next')
          ? json['show_skip_next'] as bool
          : null,
      showSettings: json.containsKey('show_settings')
          ? json['show_settings'] as bool
          : null,
      showSubtitles: json.containsKey('show_subtitles')
          ? json['show_subtitles'] as bool
          : null,
      showFullscreen: json.containsKey('show_fullscreen')
          ? json['show_fullscreen'] as bool
          : null,
      showUpNext: json.containsKey('show_up_next')
          ? json['show_up_next'] as bool
          : null,
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

  /// Embedded button visibility for [PlayerControlType.timeline] only.
  final TimelineChromeOptions? timelineOptions;

  /// Keeps [PlayerControlType.volumeSlider] permanently expanded instead of
  /// only on hover (Emby-style always-visible slider).
  final bool alwaysExpanded;

  const ControlConfig({
    required this.xPercentage,
    required this.yPercentage,
    required this.sizePercentage,
    this.widthPercentage = 0.85,
    this.timelineOptions,
    this.alwaysExpanded = false,
  });

  TimelineChromeOptions get resolvedTimelineOptions =>
      timelineOptions ?? TimelineChromeOptions.legacy();

  ControlConfig copyWith({
    double? xPercentage,
    double? yPercentage,
    double? sizePercentage,
    double? widthPercentage,
    TimelineChromeOptions? timelineOptions,
    bool? alwaysExpanded,
  }) {
    return ControlConfig(
      xPercentage: (xPercentage ?? this.xPercentage).clamp(0.0, 1.0),
      yPercentage: (yPercentage ?? this.yPercentage).clamp(0.0, 1.0),
      sizePercentage: (sizePercentage ?? this.sizePercentage)
          .clamp(kMinSizePct, kMaxSizePct),
      widthPercentage: (widthPercentage ?? this.widthPercentage)
          .clamp(kMinProgressWidthPct, 1.0),
      timelineOptions: timelineOptions ?? this.timelineOptions,
      alwaysExpanded: alwaysExpanded ?? this.alwaysExpanded,
    );
  }

  Map<String, dynamic> toJson() => {
        'x_percentage': xPercentage,
        'y_percentage': yPercentage,
        'size_percentage': sizePercentage,
        'width_percentage': widthPercentage,
        if (timelineOptions != null)
          'timeline_options': timelineOptions!.toJson(),
        'always_expanded': alwaysExpanded,
      };

  factory ControlConfig.fromJson(
    Map<String, dynamic> json, {
    PlayerControlType? controlType,
  }) {
    return ControlConfig(
      xPercentage: ((json['x_percentage'] as num?)?.toDouble() ?? 0.5)
          .clamp(0.0, 1.0),
      yPercentage: ((json['y_percentage'] as num?)?.toDouble() ?? 0.5)
          .clamp(0.0, 1.0),
      sizePercentage: ((json['size_percentage'] as num?)?.toDouble() ?? 0.08)
          .clamp(kMinSizePct, kMaxSizePct),
      widthPercentage: ((json['width_percentage'] as num?)?.toDouble() ?? 0.85)
          .clamp(kMinProgressWidthPct, 1.0),
      alwaysExpanded: json['always_expanded'] as bool? ?? false,
      timelineOptions: json['timeline_options'] is Map<String, dynamic>
          ? TimelineChromeOptions.fromJson(
              json['timeline_options'] as Map<String, dynamic>,
              defaults: controlType != null
                  ? TimelineChromeOptions.defaultsFor(controlType)
                  : null,
            )
          : null,
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

  /// Merged timeline options with type-specific defaults when none were saved.
  TimelineChromeOptions get effectiveTimelineOptions {
    final defaults = TimelineChromeOptions.defaultsFor(type);
    final saved = config.timelineOptions;
    if (saved == null) return defaults;
    return saved;
  }

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
    final type = PlayerControlTypeX.fromId(json['type'] as String? ?? 'playPause');
    return PlacedControl(
      id: (json['id'] as String?) ?? '',
      type: type,
      config: ControlConfig.fromJson(
        json['config'] as Map<String, dynamic>,
        controlType: type,
      ),
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

  /// Visual language applied to every control's chrome (one per preset).
  final ControlSkinStyle skin;

  /// Accent colour for the Flat skin (ignored by Glass/Neumorphic).
  final Color flatAccentColor;

  /// Drop-shadow strength for the Flat skin (ignored by Glass/Neumorphic).
  final FlatElevation flatElevation;

  /// Shadow/extrusion depth for the Neumorphic skin, 0.0 -> 1.0.
  final double neumorphicIntensity;

  /// When true, tapping the video toggles play/pause (modular layout only).
  final bool tapToTogglePlayback;

  /// Non-null when this preset is a hand-written, non-editable chrome.
  ///
  /// It wins over every other field here: [controls] and the appearance
  /// settings are kept only so an older client — which does not know this key
  /// — still has a usable layout to fall back on.
  final FixedChromeId? fixedChrome;

  /// Whether this preset renders a fixed chrome instead of the modular layer.
  bool get isFixedChrome => fixedChrome != null;

  /// Whether the layout already places a control of this type.
  bool hasControl(PlayerControlType type) =>
      controls.any((c) => c.type == type);

  const PlayerLayoutConfig({
    required this.controls,
    this.blurIntensity = kDefaultBlurSigma,
    this.glassOpacity = kDefaultGlassOpacity,
    this.liquidGlass = kDefaultLiquidGlass,
    this.skin = ControlSkinStyle.glass,
    this.flatAccentColor = kDefaultFlatAccentColor,
    this.flatElevation = kDefaultFlatElevation,
    this.neumorphicIntensity = kDefaultNeumorphicIntensity,
    this.tapToTogglePlayback = false,
    this.fixedChrome,
  });

  PlayerLayoutConfig copyWith({
    List<PlacedControl>? controls,
    double? blurIntensity,
    double? glassOpacity,
    bool? liquidGlass,
    ControlSkinStyle? skin,
    Color? flatAccentColor,
    FlatElevation? flatElevation,
    double? neumorphicIntensity,
    bool? tapToTogglePlayback,
    FixedChromeId? fixedChrome,
    // `fixedChrome: null` means "leave as is" like every other field here, so
    // dropping back to a modular playeur needs its own explicit flag.
    bool clearFixedChrome = false,
  }) {
    return PlayerLayoutConfig(
      controls: controls ?? this.controls,
      blurIntensity: (blurIntensity ?? this.blurIntensity)
          .clamp(kMinBlurSigma, kMaxBlurSigma),
      glassOpacity: (glassOpacity ?? this.glassOpacity)
          .clamp(kMinGlassOpacity, kMaxGlassOpacity),
      liquidGlass: liquidGlass ?? this.liquidGlass,
      skin: skin ?? this.skin,
      flatAccentColor: flatAccentColor ?? this.flatAccentColor,
      flatElevation: flatElevation ?? this.flatElevation,
      neumorphicIntensity: (neumorphicIntensity ?? this.neumorphicIntensity)
          .clamp(kMinNeumorphicIntensity, kMaxNeumorphicIntensity),
      tapToTogglePlayback: tapToTogglePlayback ?? this.tapToTogglePlayback,
      fixedChrome:
          clearFixedChrome ? null : (fixedChrome ?? this.fixedChrome),
    );
  }

  /// Default layout that mirrors the standard player look.
  ///
  /// Prefer [PlayerLayoutTemplates] prefabs when creating a full playeur.
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

  /// A preset that renders the hand-written [chrome] instead of the modular
  /// layer.
  ///
  /// It still carries the standard control list: a client too old to know
  /// `fixed_chrome` ignores the key and falls back to that layout rather than
  /// showing an empty player.
  factory PlayerLayoutConfig.fixed(FixedChromeId chrome) {
    return PlayerLayoutConfig.standard().copyWith(fixedChrome: chrome);
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

  /// Move an existing control to the end of the list so it renders on top.
  PlayerLayoutConfig withControlBroughtToFront(String id) {
    final placed = byId(id);
    if (placed == null) return this;
    return copyWith(
      controls: [
        ...controls.where((c) => c.id != id),
        placed,
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 2,
        'blur_intensity': blurIntensity,
        'glass_opacity': glassOpacity,
        'liquid_glass': liquidGlass,
        'skin': skin.id,
        'flat_accent_color': flatAccentColor.toARGB32(),
        'flat_elevation': flatElevation.id,
        'neumorphic_intensity': neumorphicIntensity,
        'tap_to_toggle_playback': tapToTogglePlayback,
        if (fixedChrome != null) 'fixed_chrome': fixedChrome!.id,
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
    final skin = ControlSkinStyle.fromId(json['skin'] as String?);
    final flatAccent = json['flat_accent_color'] is int
        ? Color(json['flat_accent_color'] as int)
        : kDefaultFlatAccentColor;
    final flatElevation = FlatElevation.fromId(json['flat_elevation'] as String?);
    final neumorphicIntensity =
        ((json['neumorphic_intensity'] as num?)?.toDouble() ??
                kDefaultNeumorphicIntensity)
            .clamp(kMinNeumorphicIntensity, kMaxNeumorphicIntensity);
    final tapPlayback = json['tap_to_toggle_playback'] as bool? ?? false;
    final fixedChrome = FixedChromeId.fromId(json['fixed_chrome'] as String?);

    // New format (v2)
    if (json['controls'] is List) {
      final list = (json['controls'] as List).cast<Map<String, dynamic>>();
      return PlayerLayoutConfig(
        controls: list.map(PlacedControl.fromJson).toList(),
        blurIntensity: blur,
        glassOpacity: opacity,
        liquidGlass: liquid,
        skin: skin,
        flatAccentColor: flatAccent,
        flatElevation: flatElevation,
        neumorphicIntensity: neumorphicIntensity,
        tapToTogglePlayback: tapPlayback,
        fixedChrome: fixedChrome,
      );
    }
    // Migrate from old v1 format (Map<typeId, config>)
    return _migrateFromV1(json).copyWith(
      blurIntensity: blur,
      glassOpacity: opacity,
      liquidGlass: liquid,
      skin: skin,
      flatAccentColor: flatAccent,
      flatElevation: flatElevation,
      neumorphicIntensity: neumorphicIntensity,
      tapToTogglePlayback: tapPlayback,
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
          config: ControlConfig.fromJson(raw, controlType: type),
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
    final emphasis =
        placed.type == PlayerControlType.playPause ? 1.15 : 1.0;
    final pixelSize = modularControlPixelSize(
      screenSize,
      config.sizePercentage,
      emphasis: emphasis,
    );

    switch (placed.type) {
      case PlayerControlType.progressBar:
        final barHeight = (pixelSize * 0.4).clamp(10.0, 32.0);
        final verticalPadding = (barHeight / 2).clamp(8.0, 16.0) * 2;
        return Size(
          screenSize.width * config.widthPercentage.clamp(0.1, 1.0),
          barHeight + verticalPadding,
        );
      case PlayerControlType.timeline:
      case PlayerControlType.timelineEmby:
      case PlayerControlType.timelineGlassInline:
        final opts = config.resolvedTimelineOptions;
        final isEmby = placed.type == PlayerControlType.timelineEmby ||
            opts.visualStyle == TimelineVisualStyle.emby;
        final isInline = placed.type == PlayerControlType.timelineGlassInline;
        final baseHeight = (pixelSize * 0.5).clamp(14.0, 40.0);
        final iconSize = (baseHeight * 0.72).clamp(16.0, 26.0);
        final textLineHeight = (baseHeight * 0.45).clamp(10.0, 16.0) * 1.25;
        if (isEmby) {
          var height = 12.0 + 8 + textLineHeight + 8;
          if (opts.hasLeftCluster) height += iconSize + 12;
          height += 8;
          return Size(screenSize.width, height);
        }
        if (isInline) {
          return Size(screenSize.width, iconSize + 4 + 10);
        }
        final topBlock = textLineHeight + 4 + baseHeight * 0.55;
        var height = topBlock + 16; // vertical padding (vPad * 2)
        if (opts.hasBottomRow) {
          height += iconSize + 4 + 6; // bottom row icons + gap
        }
        return Size(
          screenSize.width * config.widthPercentage.clamp(0.3, 1.0),
          height,
        );
      case PlayerControlType.mediaTitle:
        final height = (pixelSize * 0.8).clamp(24.0, 48.0);
        return Size(screenSize.width * 0.5, height);
      case PlayerControlType.mediaLogo:
        final height =
            (pixelSize * kControlChromePaddingFactor).clamp(36.0, 100.0);
        return Size(screenSize.width * 0.38, height);
      case PlayerControlType.volumeSlider:
        final height = (pixelSize * 0.5).clamp(16.0, 40.0);
        return Size(
          screenSize.width * config.widthPercentage.clamp(0.05, 0.5),
          height,
        );
      case PlayerControlType.upNext:
        final height =
            (pixelSize * kControlChromePaddingFactor).clamp(36.0, 52.0);
        return Size(height * 2.75, height);
      case PlayerControlType.upNextEmby:
        final height = (pixelSize * 1.2).clamp(28.0, 40.0);
        return Size(height * 2.5, height);
      case PlayerControlType.skipIntro:
        final height = (pixelSize * 1.15).clamp(32.0, 44.0);
        return Size(height * 3.2, height);
      case PlayerControlType.playbackSpeed:
      case PlayerControlType.timeRemaining:
        final height = (pixelSize * 1.15).clamp(30.0, 42.0);
        return Size(height * 2.4, height);
      case PlayerControlType.aspectFit:
      case PlayerControlType.audioTracks:
      case PlayerControlType.chapters:
      case PlayerControlType.rewind30:
      case PlayerControlType.forward30:
        final diameter = pixelSize * kControlChromePaddingFactor;
        return Size(diameter, diameter);
      default:
        final diameter = pixelSize * kControlChromePaddingFactor;
        return Size(diameter, diameter);
    }
  }
}
