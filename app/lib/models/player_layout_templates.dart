import 'package:flutter/material.dart';

import 'player_layout.dart';

/// Prefabricated playeur models for Player Studio.
///
/// Every template guarantees the same [PlayerCoreRole] set. Some add extras
/// on top — never remove a core role.
enum PlayerTemplateId {
  cinema,
  series,
  pro,
  classic,
  net,
  doux,
}

/// Mandatory playback roles every prefab must expose (discrete control and/or
/// embedded timeline chrome).
enum PlayerCoreRole {
  back,
  mediaTitle,
  playPause,
  rewind,
  forward,
  scrubber,
  subtitles,
  settings,
  fullscreen,
}

/// Catalog entry shown in « Choisir un modèle ».
class PlayerLayoutTemplate {
  final PlayerTemplateId id;
  final String name;
  final String tagline;
  final String description;
  final IconData icon;
  final List<String> extrasLabels;
  final bool useModular;
  final PlayerLayoutConfig Function() build;

  const PlayerLayoutTemplate({
    required this.id,
    required this.name,
    required this.tagline,
    required this.description,
    required this.icon,
    required this.extrasLabels,
    required this.useModular,
    required this.build,
  });

  /// Builds config and asserts CORE roles are present.
  PlayerLayoutConfig buildValidated() {
    final config = build();
    final missing = config.missingCoreRoles();
    assert(
      missing.isEmpty,
      'Template ${id.name} missing core roles: $missing',
    );
    return config;
  }
}

/// All selectable prefabricated playeurs (+ used by the picker UI).
abstract final class PlayerLayoutTemplates {
  static List<PlayerLayoutTemplate> get all => [
        PlayerLayoutTemplate(
          id: PlayerTemplateId.cinema,
          name: 'Cinéma',
          tagline: 'Immersion, peu de chrome',
          description:
              'CORE + muet : HUD bas (transport collé à la timeline), boutons '
              'compacts pensés PC / mobile / TV. Tap image = play/pause.',
          icon: Icons.movie_outlined,
          extrasLabels: const ['Muet'],
          useModular: true,
          build: cinema,
        ),
        PlayerLayoutTemplate(
          id: PlayerTemplateId.series,
          name: 'Séries',
          tagline: 'Binge sans friction',
          description:
              'CORE + épisodes, passer l’intro et à suivre — pensé pour les saisons.',
          icon: Icons.live_tv_outlined,
          extrasLabels: const [
            'Épisode ±',
            'Passer l’intro',
            'À suivre',
          ],
          useModular: true,
          build: series,
        ),
        PlayerLayoutTemplate(
          id: PlayerTemplateId.pro,
          name: 'Pro',
          tagline: 'Contrôle densifié',
          description:
              'CORE + volume, audio, vitesse, chapitres, cadrage et temps restant.',
          icon: Icons.tune_rounded,
          extrasLabels: const [
            'Volume',
            'Audio',
            'Vitesse',
            'Chapitres',
            'Cadrage',
            'Temps restant',
          ],
          useModular: true,
          build: pro,
        ),
        PlayerLayoutTemplate(
          id: PlayerTemplateId.classic,
          name: 'Classique',
          tagline: 'Barre dense familière',
          description:
              'CORE dans une timeline Emby : transport et utilitaires regroupés en bas.',
          icon: Icons.view_timeline_outlined,
          extrasLabels: const [],
          useModular: true,
          build: classic,
        ),
        PlayerLayoutTemplate(
          id: PlayerTemplateId.net,
          name: 'Net',
          tagline: 'Aplats francs, zéro flou',
          description:
              'CORE dans une barre basse dense, skin Flat : surfaces pleines, '
              'sans transparence ni flou, couleur d’accent au choix.',
          icon: Icons.crop_square_rounded,
          extrasLabels: const [],
          useModular: true,
          build: net,
        ),
        PlayerLayoutTemplate(
          id: PlayerTemplateId.doux,
          name: 'Doux',
          tagline: 'Boutons moelleux, ombres douces',
          description:
              'CORE centré et espacé, skin Néomorphique : contrôles extrudés '
              'du fond par de doubles ombres, sans couleur ni flou.',
          icon: Icons.blur_circular_rounded,
          extrasLabels: const [],
          useModular: true,
          build: doux,
        ),
      ];

  static PlayerLayoutTemplate? byId(PlayerTemplateId id) {
    for (final t in all) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Immersive CORE layout — compact HUD for phone, desktop and TV.
  ///
  /// Transport sits just above the timeline (cinema chrome), utilities stay in
  /// a tight top-right cluster, sizes stay low so [modularControlPixelSize]
  /// clamps cleanly across devices.
  static PlayerLayoutConfig cinema() {
    const topY = 0.075;
    const utilSize = 0.038;
    const transportY = 0.84;
    const seekSize = 0.040;
    const playSize = 0.048;

    return PlayerLayoutConfig(
      blurIntensity: 12,
      glassOpacity: 0.055,
      liquidGlass: false,
      tapToTogglePlayback: true,
      controls: [
        // Top — back + title (left), utilities (right, tight)
        _btn('back', PlayerControlType.back,
            x: 0.06, y: topY, size: utilSize),
        _btn('mediaTitle', PlayerControlType.mediaTitle,
            x: 0.22, y: topY, size: utilSize),
        _btn('mute', PlayerControlType.mute,
            x: 0.72, y: topY, size: utilSize),
        _btn('settings', PlayerControlType.settings,
            x: 0.80, y: topY, size: utilSize),
        _btn('subtitles', PlayerControlType.subtitles,
            x: 0.87, y: topY, size: utilSize),
        _btn('fullscreen', PlayerControlType.fullscreen,
            x: 0.94, y: topY, size: utilSize),

        // Transport — above scrubber, compact cluster
        _btn('rewind', PlayerControlType.rewind,
            x: 0.43, y: transportY, size: seekSize),
        _btn('playPause', PlayerControlType.playPause,
            x: 0.50, y: transportY - 0.005, size: playSize),
        _btn('forward', PlayerControlType.forward,
            x: 0.57, y: transportY, size: seekSize),

        // Timeline — bottom edge, readable scrub hit area
        _bar(
          'timeline',
          PlayerControlType.timelineGlassInline,
          x: 0.5,
          y: 0.93,
          size: 0.050,
          width: 0.86,
          timelineOptions: _scrubOnlyChrome,
        ),
      ],
    );
  }

  /// CORE + binge extras (episodes, skip intro, up next).
  static PlayerLayoutConfig series() {
    return PlayerLayoutConfig(
      blurIntensity: 8,
      glassOpacity: 0.07,
      liquidGlass: false,
      tapToTogglePlayback: true,
      controls: [
        ..._coreTopBar(),
        _btn('skipPrevious', PlayerControlType.skipPrevious,
            x: 0.26, y: 0.78, size: 0.07),
        ..._coreTransport(y: 0.78),
        _btn('skipNext', PlayerControlType.skipNext, x: 0.74, y: 0.78, size: 0.07),
        _btn('skipIntro', PlayerControlType.skipIntro, x: 0.88, y: 0.68, size: 0.07),
        _btn('upNext', PlayerControlType.upNext, x: 0.12, y: 0.68, size: 0.07),
        _bar(
          'timeline',
          PlayerControlType.timeline,
          x: 0.5,
          y: 0.90,
          size: 0.05,
          width: 0.90,
          timelineOptions: _scrubOnlyChrome,
        ),
      ],
    );
  }

  /// CORE + power-user extras.
  static PlayerLayoutConfig pro() {
    return PlayerLayoutConfig(
      blurIntensity: 8,
      glassOpacity: 0.08,
      liquidGlass: true,
      tapToTogglePlayback: false,
      controls: [
        _btn('back', PlayerControlType.back, x: 0.05, y: 0.08, size: 0.07),
        _btn('mediaTitle', PlayerControlType.mediaTitle,
            x: 0.28, y: 0.08, size: 0.055),
        _btn('timeRemaining', PlayerControlType.timeRemaining,
            x: 0.55, y: 0.08, size: 0.055),
        _btn('audioTracks', PlayerControlType.audioTracks,
            x: 0.68, y: 0.08, size: 0.065),
        _btn('settings', PlayerControlType.settings, x: 0.78, y: 0.08, size: 0.065),
        _btn('subtitles', PlayerControlType.subtitles, x: 0.86, y: 0.08, size: 0.065),
        _btn('fullscreen', PlayerControlType.fullscreen,
            x: 0.94, y: 0.08, size: 0.065),
        _btn('volumeSlider', PlayerControlType.volumeSlider,
            x: 0.08, y: 0.55, size: 0.08),
        _btn('chapters', PlayerControlType.chapters, x: 0.94, y: 0.55, size: 0.07),
        _btn('playbackSpeed', PlayerControlType.playbackSpeed,
            x: 0.94, y: 0.42, size: 0.065),
        _btn('aspectFit', PlayerControlType.aspectFit, x: 0.94, y: 0.30, size: 0.065),
        ..._coreTransport(y: 0.76),
        _bar(
          'timeline',
          PlayerControlType.timeline,
          x: 0.5,
          y: 0.88,
          size: 0.055,
          width: 0.88,
          timelineOptions: _scrubOnlyChrome,
        ),
      ],
    );
  }

  /// CORE via Emby-style timeline chrome (+ top back/title).
  static PlayerLayoutConfig classic() {
    return PlayerLayoutConfig(
      blurIntensity: 6,
      glassOpacity: 0.04,
      liquidGlass: false,
      tapToTogglePlayback: false,
      controls: [
        _btn('back', PlayerControlType.back, x: 0.06, y: 0.08, size: 0.07),
        _btn('mediaTitle', PlayerControlType.mediaTitle,
            x: 0.35, y: 0.08, size: 0.06),
        _bar(
          'timelineEmby',
          PlayerControlType.timelineEmby,
          x: 0.5,
          y: 0.88,
          size: 0.06,
          width: 0.94,
          timelineOptions: const TimelineChromeOptions(
            visualStyle: TimelineVisualStyle.emby,
            showSkipPrevious: false,
            showRewind: true,
            showPlayPause: true,
            showForward: true,
            showSkipNext: false,
            showSettings: true,
            showSubtitles: true,
            showFullscreen: true,
            showUpNext: false,
          ),
        ),
      ],
    );
  }

  /// Flat skin, CORE only — one dense flat bar low on screen (back + title
  /// tucked just above it) instead of controls scattered across the frame.
  static PlayerLayoutConfig net() {
    return PlayerLayoutConfig(
      skin: ControlSkinStyle.flat,
      tapToTogglePlayback: false,
      controls: [
        _btn('back', PlayerControlType.back, x: 0.06, y: 0.08, size: 0.065),
        _btn('mediaTitle', PlayerControlType.mediaTitle,
            x: 0.20, y: 0.08, size: 0.055),
        _bar(
          'timeline',
          PlayerControlType.timeline,
          x: 0.5,
          y: 0.92,
          size: 0.055,
          width: 0.94,
          timelineOptions: TimelineChromeOptions.flat(),
        ),
      ],
    );
  }

  /// Neumorphic skin, CORE only — centered transport with wide gaps so the
  /// soft extrusion shadows have room to read on every control.
  static PlayerLayoutConfig doux() {
    return PlayerLayoutConfig(
      skin: ControlSkinStyle.neumorphic,
      tapToTogglePlayback: false,
      controls: [
        _btn('back', PlayerControlType.back, x: 0.06, y: 0.08, size: 0.065),
        _btn('mediaTitle', PlayerControlType.mediaTitle,
            x: 0.5, y: 0.08, size: 0.055),
        _btn('rewind', PlayerControlType.rewind, x: 0.22, y: 0.55, size: 0.075),
        _btn('playPause', PlayerControlType.playPause,
            x: 0.5, y: 0.50, size: 0.11),
        _btn('forward', PlayerControlType.forward, x: 0.78, y: 0.55, size: 0.075),
        _bar(
          'timeline',
          PlayerControlType.timeline,
          x: 0.5,
          y: 0.90,
          size: 0.055,
          width: 0.90,
          timelineOptions: const TimelineChromeOptions(
            visualStyle: TimelineVisualStyle.neumorphic,
            showSkipPrevious: false,
            showRewind: false,
            showPlayPause: false,
            showForward: false,
            showSkipNext: false,
            showSettings: true,
            showSubtitles: true,
            showFullscreen: true,
            showUpNext: false,
          ),
        ),
      ],
    );
  }
}

extension PlayerLayoutConfigCoreX on PlayerLayoutConfig {
  /// Whether this layout exposes every mandatory playback role.
  bool get satisfiesCoreRoles => missingCoreRoles().isEmpty;

  List<PlayerCoreRole> missingCoreRoles() {
    final missing = <PlayerCoreRole>[];
    for (final role in PlayerCoreRole.values) {
      if (!_hasCoreRole(role)) missing.add(role);
    }
    return missing;
  }

  bool _hasCoreRole(PlayerCoreRole role) {
    final timeline = _firstTimeline;
    final opts = timeline?.effectiveTimelineOptions;

    switch (role) {
      case PlayerCoreRole.back:
        return hasControl(PlayerControlType.back);
      case PlayerCoreRole.mediaTitle:
        return hasControl(PlayerControlType.mediaTitle) ||
            hasControl(PlayerControlType.mediaLogo) ||
            hasControl(PlayerControlType.episodeTitleBlock);
      case PlayerCoreRole.playPause:
        return hasControl(PlayerControlType.playPause) ||
            (opts?.showPlayPause ?? false);
      case PlayerCoreRole.rewind:
        return hasControl(PlayerControlType.rewind) ||
            hasControl(PlayerControlType.rewind30) ||
            (opts?.showRewind ?? false);
      case PlayerCoreRole.forward:
        return hasControl(PlayerControlType.forward) ||
            hasControl(PlayerControlType.forward30) ||
            (opts?.showForward ?? false);
      case PlayerCoreRole.scrubber:
        return hasControl(PlayerControlType.progressBar) ||
            controls.any((c) => c.type.isTimelineBar);
      case PlayerCoreRole.subtitles:
        return hasControl(PlayerControlType.subtitles) ||
            (opts?.showSubtitles ?? false);
      case PlayerCoreRole.settings:
        return hasControl(PlayerControlType.settings) ||
            (opts?.showSettings ?? false);
      case PlayerCoreRole.fullscreen:
        return hasControl(PlayerControlType.fullscreen) ||
            (opts?.showFullscreen ?? false);
    }
  }

  PlacedControl? get _firstTimeline {
    for (final c in controls) {
      if (c.type.isTimelineBar || c.type == PlayerControlType.progressBar) {
        return c;
      }
    }
    return null;
  }
}

// ── Shared placement helpers ───────────────────────────────────────────────

PlacedControl _btn(
  String id,
  PlayerControlType type, {
  required double x,
  required double y,
  double size = 0.075,
  bool alwaysExpanded = false,
}) {
  return PlacedControl(
    id: id,
    type: type,
    config: ControlConfig(
      xPercentage: x,
      yPercentage: y,
      sizePercentage: size,
      alwaysExpanded: alwaysExpanded,
    ),
  );
}

PlacedControl _bar(
  String id,
  PlayerControlType type, {
  required double x,
  required double y,
  double size = 0.055,
  double width = 0.88,
  TimelineChromeOptions? timelineOptions,
  bool alwaysExpanded = false,
}) {
  return PlacedControl(
    id: id,
    type: type,
    config: ControlConfig(
      xPercentage: x,
      yPercentage: y,
      sizePercentage: size,
      widthPercentage: width,
      timelineOptions: timelineOptions,
      alwaysExpanded: alwaysExpanded,
    ),
  );
}

/// Scrub-only chrome — transport lives on discrete CORE buttons.
const _scrubOnlyChrome = TimelineChromeOptions(
  visualStyle: TimelineVisualStyle.glass,
  showSkipPrevious: false,
  showRewind: false,
  showPlayPause: false,
  showForward: false,
  showSkipNext: false,
  showSettings: false,
  showSubtitles: false,
  showFullscreen: false,
  showUpNext: false,
);

List<PlacedControl> _coreTopBar() => [
      _btn('back', PlayerControlType.back, x: 0.06, y: 0.08, size: 0.07),
      _btn('mediaTitle', PlayerControlType.mediaTitle, x: 0.32, y: 0.08, size: 0.06),
      _btn('settings', PlayerControlType.settings, x: 0.78, y: 0.08, size: 0.07),
      _btn('subtitles', PlayerControlType.subtitles, x: 0.86, y: 0.08, size: 0.07),
      _btn('fullscreen', PlayerControlType.fullscreen, x: 0.94, y: 0.08, size: 0.07),
    ];

List<PlacedControl> _coreTransport({double y = 0.78}) => [
      _btn('rewind', PlayerControlType.rewind, x: 0.38, y: y, size: 0.075),
      _btn('playPause', PlayerControlType.playPause,
          x: 0.5, y: y - 0.01, size: 0.11),
      _btn('forward', PlayerControlType.forward, x: 0.62, y: y, size: 0.075),
    ];
