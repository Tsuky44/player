import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../playback/playback_session.dart';
import '../../playback/sleep_timer.dart';

import '../../../../models/models.dart';
import '../../../../tv/tv_focus.dart';
import '../../../../tv/tv_mode.dart';
import '../../../../utils/app_platform.dart';
import '../../hooks/use_episode_navigation.dart';
import '../../hooks/use_player_controller.dart';
import '../direct_source_label.dart';
import '../track_label.dart';
import 'onyx_chrome_theme.dart';
import '../../../../theme/app_type.dart';
import '../../../../l10n/tr.dart';

part 'onyx_settings_menu_rows.dart';

/// Which list the menu is showing. [root] is the index of sections.
enum OnyxMenuSection {
  root,
  quality,
  audio,
  subtitles,
  speed,
  display,
  sleep,
  chapters,
}

/// Chrome Onyx settings menu: a narrow list of sections, each drilling into a
/// list of choices, instead of a tall tabbed panel.
///
/// A tabbed panel shows every category's chrome at once —
/// header, subtitle, five segmented tabs — before showing a single option. On
/// Chrome Onyx that reads as a dialog dropped on the video. This menu instead
/// puts one column of rows over the picture: what each setting is *currently*
/// on is visible without opening anything, and a category costs one tap.
///
/// Like the rest of this chrome, the look is locked — see [OnyxChromeTheme].
class OnyxSettingsMenu extends StatefulWidget {
  final PlaybackSession session;
  final PlayerController? playerController;
  final EpisodeNavigationController? episodeNav;

  final BoxFit currentFit;
  final ValueChanged<BoxFit> onFitChanged;

  final double playbackRate;
  final List<double> playbackRates;
  final ValueChanged<double> onRateChanged;

  final Future<void> Function(int absoluteSeconds)? onSeekToAbsolute;

  /// Opening straight on a category — the CC and audio buttons of the chrome
  /// point at their own list rather than at the index.
  final OnyxMenuSection initialSection;

  final VoidCallback onClose;

  const OnyxSettingsMenu({
    super.key,
    required this.session,
    required this.currentFit,
    required this.onFitChanged,
    required this.playbackRate,
    required this.playbackRates,
    required this.onRateChanged,
    required this.onClose,
    this.playerController,
    this.episodeNav,
    this.onSeekToAbsolute,
    this.initialSection = OnyxMenuSection.root,
  });

  static const double width = 292;
  static const double maxHeight = 420;

  @override
  State<OnyxSettingsMenu> createState() => _OnyxSettingsMenuState();
}

class _OnyxSettingsMenuState extends State<OnyxSettingsMenu> {
  late OnyxMenuSection _section;
  late BoxFit _fit;
  StreamSubscription<void>? _tracksSubscription;

  /// Fait avancer le « reste 23 min » tant que la minuterie de veille court.
  Timer? _sleepRefresh;

  /// Where the remote lands on the list currently shown: the value already in
  /// force inside a section, the row it came back from on the index.
  ///
  /// One node moved from row to row on every section change, rather than an
  /// `autofocus` on each: two rows claiming the entry point is a ring that
  /// jumps.
  final FocusNode _entryNode = FocusNode(debugLabel: 'onyx-menu-entry');

  /// The section just left, so the index puts the ring back on its row instead
  /// of dropping the user at the top of the list.
  OnyxMenuSection? _returnedFrom;

  PlayerController? get _controller => widget.playerController;

  @override
  void initState() {
    super.initState();
    _section = widget.initialSection;
    _fit = widget.currentFit;
    _tracksSubscription = _controller?.tracksStream.listen((_) {
      if (mounted) setState(() {});
    });
    SleepTimer.instance.addListener(_handleSleepTimerChanged);
    _syncSleepRefresh();
    _focusEntryAfterBuild();
  }

  @override
  void dispose() {
    SleepTimer.instance.removeListener(_handleSleepTimerChanged);
    _sleepRefresh?.cancel();
    _tracksSubscription?.cancel();
    _entryNode.dispose();
    super.dispose();
  }

  void _handleSleepTimerChanged() {
    _syncSleepRefresh();
    if (mounted) setState(() {});
  }

  /// Un réveil par minute affichée, posé sur l'instant où le libellé change —
  /// pas une boucle : le menu ne se redessine que lorsqu'il a autre chose à
  /// dire.
  void _syncSleepRefresh() {
    _sleepRefresh?.cancel();
    _sleepRefresh = null;
    final remaining = SleepTimer.instance.remaining;
    if (remaining == null) return;
    final untilNextMinute = Duration(
      microseconds: remaining.inMicroseconds % Duration.microsecondsPerMinute,
    );
    _sleepRefresh = Timer(
      // Juste après le changement, pour ne pas relire la même minute.
      untilNextMinute + const Duration(milliseconds: 50),
      () {
        if (!mounted) return;
        setState(() {});
        _syncSleepRefresh();
      },
    );
  }

  // --- Remote navigation ---------------------------------------------------

  /// Puts the remote on the entry point of the list now showing.
  ///
  /// After the frame: the list has just been replaced, and [_entryNode] is
  /// attached to a row only once that row is built. Waiting is also what makes
  /// this choice win over the popup's generic "focus the first thing you find"
  /// — on a track list the ring belongs on the language being played, not on
  /// whatever happens to be at the top.
  void _focusEntryAfterBuild() {
    // Off a television nobody asked for the focus, and taking it would paint a
    // ring neither the pointer nor a finger called for.
    if (!TvMode.isTv) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _entryNode.requestFocus();
    });
  }

  void _openSection(OnyxMenuSection section) {
    setState(() => _section = section);
    _focusEntryAfterBuild();
  }

  void _backToRoot() {
    setState(() {
      _returnedFrom = _section;
      _section = OnyxMenuSection.root;
    });
    _focusEntryAfterBuild();
  }

  /// The index row the remote lands on.
  OnyxMenuSection get _rootEntry =>
      _returnedFrom ??
      (_hasQuality ? OnyxMenuSection.quality : OnyxMenuSection.audio);

  /// Back and left go up one level instead of closing everything.
  ///
  /// The menu shows a hierarchy — an index, a section — and the remote has to
  /// be able to climb it the same way it came down. On the index the key is
  /// left alone: it reaches the popup, which closes the menu, and that is the
  /// right next step up.
  KeyEventResult _handleMenuKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_section == OnyxMenuSection.root) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (kTvBackKeys.contains(key) ||
        key == LogicalKeyboardKey.arrowLeft) {
      _backToRoot();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- Section availability ------------------------------------------------

  bool get _hasChapters =>
      widget.episodeNav != null &&
      widget.episodeNav!.chapters.isNotEmpty &&
      widget.onSeekToAbsolute != null;

  bool get _hasQuality => _controller != null;

  // --- Current-value summaries shown on the root rows ----------------------

  String get _qualityValue {
    final quality = _controller?.currentQuality;
    if (quality == null) {
      return directSourceLabel(local: _controller?.isLocalPlayback ?? false)
          .label;
    }
    // La ligne de résumé est étroite : la résolution seule, sans le débit qui
    // l'accompagne dans le menu déroulé.
    for (final tier in _qualityTiers) {
      if (tier.key == quality) return tier.resolutionLabel;
    }
    return quality == '2160p' ? '4K' : quality;
  }

  String get _audioValue {
    final controller = _controller;
    final tracks = controller?.mediaTracks?.audio;
    if (controller != null && tracks != null && tracks.isNotEmpty) {
      final index = controller.selectedAudioIndex;
      if (index >= 0 && index < tracks.length) {
        return splitTrackLabel(tracks[index].displayName).$1;
      }
      return '—';
    }
    final current = widget.session.currentAudioTrack;
    if (current == null || current.id == 'no') return tr('Désactivé');
    return current.title ?? current.language ?? tr('Piste 1');
  }

  String get _subtitlesValue {
    final controller = _controller;
    if (controller == null) return '—';

    if (controller.currentQuality == null) {
      final current = widget.session.currentSubtitleTrack;
      if (current == null || current.id == 'no') return tr('Désactivés');
      return current.title ?? current.language ?? tr('Piste 1');
    }

    final lang = controller.selectedSubtitleLang;
    if (lang == null) return tr('Désactivés');
    final track = controller.mediaTracks?.subtitles
        .where((s) => s.lang == lang)
        .firstOrNull;
    return track == null ? lang : splitTrackLabel(track.displayName).$1;
  }

  String get _speedValue =>
      widget.playbackRate == 1.0 ? tr('Normale') : '${_trimRate(widget.playbackRate)}×';

  String get _displayValue => _fit == BoxFit.cover ? tr('Adaptatif') : tr('Original');

  String get _sleepValue {
    final episodes = SleepTimer.instance.episodesLeft;
    if (episodes != null) return _sleepEpisodes(episodes);
    final remaining = SleepTimer.instance.remaining;
    return remaining == null ? tr('Désactivée') : _sleepRemaining(remaining);
  }

  /// Arrondi à la minute supérieure : « 1 min » tant qu'il reste du temps,
  /// jamais un « 0 min » qui annoncerait une coupure déjà faite.
  static String _sleepRemaining(Duration remaining) {
    final minutes = (remaining.inSeconds / 60).ceil();
    if (minutes < 60) return '$minutes min';
    final rest = (minutes % 60).toString().padLeft(2, '0');
    return '${minutes ~/ 60} h $rest';
  }

  static String _sleepEpisodes(int count) =>
      tr('{0} épisode{1}', [count, count > 1 ? 's' : '']);

  static String _sleepChoiceLabel(Duration choice) {
    if (choice.inMinutes < 60) return '${choice.inMinutes} minutes';
    final hours = choice.inHours;
    return hours == 1 ? '1 heure' : '$hours heures';
  }

  static String _trimRate(double rate) {
    final text = rate.toStringAsFixed(2);
    return text.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  static String _timecode(double seconds) {
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Focus(
      // Never a destination itself: this node is here only to see the keys
      // travelling up from the focused row.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleMenuKey,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: OnyxSettingsMenu.width,
          decoration: BoxDecoration(
            // Flat surface, no blur: this chrome renders no glass anywhere.
            color: OnyxChromeTheme.tooltipSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 32,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          // Height follows the visible section, so leaving a 12-chapter list
          // for "Affichage" shrinks the menu instead of leaving a hole.
          child: AnimatedSize(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxHeight: OnyxSettingsMenu.maxHeight,
              ),
              child: _section == OnyxMenuSection.root
                  ? _buildRoot()
                  : _buildSection(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRoot() {
    Widget row(OnyxMenuSection section, String label, String value) {
      return _OnyxMenuRow(
        label: label,
        value: value,
        focusNode: _rootEntry == section ? _entryNode : null,
        onTap: () => _openSection(section),
      );
    }

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        if (_hasQuality)
          row(OnyxMenuSection.quality, tr('Qualité'), _qualityValue),
        row(OnyxMenuSection.audio, tr('Audio'), _audioValue),
        row(OnyxMenuSection.subtitles, tr('Sous-titres'), _subtitlesValue),
        row(OnyxMenuSection.speed, tr('Vitesse de lecture'), _speedValue),
        row(OnyxMenuSection.display, tr('Affichage'), _displayValue),
        row(OnyxMenuSection.sleep, tr('Minuterie de veille'), _sleepValue),
        if (_hasChapters)
          row(
            OnyxMenuSection.chapters,
            tr('Chapitres'),
            '${widget.episodeNav!.chapters.length}',
          ),
      ],
    );
  }

  Widget _buildSection() {
    final (title, body) = switch (_section) {
      OnyxMenuSection.quality => (tr('Qualité'), _buildQuality()),
      OnyxMenuSection.audio => (tr('Audio'), _buildAudio()),
      OnyxMenuSection.subtitles => (tr('Sous-titres'), _buildSubtitles()),
      OnyxMenuSection.speed => (tr('Vitesse de lecture'), _buildSpeed()),
      OnyxMenuSection.display => (tr('Affichage'), _buildDisplay()),
      OnyxMenuSection.sleep => (tr('Minuterie de veille'), _buildSleep()),
      OnyxMenuSection.chapters => (tr('Chapitres'), _buildChapters()),
      OnyxMenuSection.root => ('', const SizedBox.shrink()),
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _OnyxMenuBackHeader(title: title, onBack: _backToRoot),
        Flexible(child: body),
      ],
    );
  }

  /// Lays out a section and decides which of its rows the remote arrives on.
  ///
  /// The option already in force, so opening "Audio" outlines the language
  /// being played and the next press moves from there. A list with nothing
  /// selected — the chapters — hands it to the first row.
  Widget _sectionList(List<_OnyxMenuOption> options) {
    final selected = options.indexWhere((option) => option.selected);
    final entry = selected < 0 ? 0 : selected;

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 6),
      children: [
        for (var i = 0; i < options.length; i++)
          options[i].withFocusNode(i == entry ? _entryNode : null),
      ],
    );
  }

  // --- Sections ------------------------------------------------------------

  /// Les barreaux figés d'avant l'échelle annoncée par le serveur.
  ///
  /// Un serveur plus ancien ne renvoie pas de `qualities`, et la médiathèque
  /// peut en réunir plusieurs (ADR-0013) : le menu doit rester utilisable en
  /// face de celui qui ne sait pas encore répondre. Ces cinq clés existent
  /// toujours côté serveur et gardent leurs débits d'origine.
  static const _legacyQualities = <QualityTier>[
    QualityTier(key: '2160p', label: '4K', height: 2160, bitrateBps: 0),
    QualityTier(key: '1080p', label: '1080p', height: 1080, bitrateBps: 0),
    QualityTier(key: '720p', label: '720p', height: 720, bitrateBps: 0),
    QualityTier(key: '480p', label: '480p', height: 480, bitrateBps: 0),
    QualityTier(key: '360p', label: '360p', height: 360, bitrateBps: 0),
  ];

  List<QualityTier> get _qualityTiers {
    final offered = _controller?.mediaTracks?.qualities ?? const <QualityTier>[];
    return offered.isEmpty ? _legacyQualities : offered;
  }

  Widget _buildQuality() {
    final controller = _controller;
    if (controller == null) return const _OnyxMenuEmpty();
    final direct = directSourceLabel(
      local: controller.isLocalPlayback,
      streamSubtitle: tr('Le fichier tel quel'),
    );

    return _sectionList([
      // Direct Play is native-only: it hands the player the file itself, which
      // a browser cannot open.
      if (!AppPlatform.isWeb)
        _OnyxMenuOption(
          label: direct.label,
          subtitle: direct.subtitle,
          selected: controller.currentQuality == null,
          onTap: () {
            widget.onClose();
            controller.chooseQuality(null);
          },
        ),
      for (final tier in _qualityTiers)
        () {
          return _OnyxMenuOption(
            label: tier.resolutionLabel,
            subtitle: tier.bitrateLabel,
            selected: controller.currentQuality == tier.key,
            onTap: () {
              widget.onClose();
              controller.chooseQuality(tier.key);
            },
          );
        }(),
    ]);
  }

  Widget _buildAudio() {
    final controller = _controller;
    final tracks = controller?.mediaTracks?.audio;

    if (controller != null && tracks != null && tracks.isNotEmpty) {
      return _sectionList([
        for (var i = 0; i < tracks.length; i++)
          () {
            final (title, subtitle) = splitTrackLabel(tracks[i].displayName);
            final selected = i == controller.selectedAudioIndex;
            return _OnyxMenuOption(
              label: title,
              subtitle: subtitle,
              selected: selected,
              onTap: () {
                if (!selected) controller.switchAudioTrack(i);
                widget.onClose();
              },
            );
          }(),
      ]);
    }

    final internal = widget.session.audioTracks;
    if (internal.isEmpty) return const _OnyxMenuEmpty();
    final current = widget.session.currentAudioTrack;

    return _sectionList([
      for (var i = 0; i < internal.length; i++)
        _OnyxMenuOption(
          label: internal[i].id == 'no'
              ? tr('Désactivé')
              : internal[i].title ??
                  (internal[i].language != null
                      ? tr('Audio ({0})', [internal[i].language])
                      : tr('Audio {0}', [i + 1])),
          selected: internal[i] == current,
          onTap: () {
            widget.session.setAudioTrack(internal[i]);
            widget.onClose();
          },
        ),
    ]);
  }

  Widget _buildSubtitles() {
    final controller = _controller;
    if (controller == null) return const _OnyxMenuEmpty();

    // Direct Play reads the tracks off the file; a transcode carries the
    // canonical list from the server. Same split as [PlayerSubtitlesPicker].
    if (controller.currentQuality == null) {
      final subs = widget.session.subtitleTracks
          .where((t) => t.id != 'auto')
          .toList();
      if (subs.isEmpty) return const _OnyxMenuEmpty();
      final current = widget.session.currentSubtitleTrack;

      return _sectionList([
        for (var i = 0; i < subs.length; i++)
          _OnyxMenuOption(
            label: subs[i].id == 'no'
                ? tr('Désactivés')
                : subs[i].title ??
                    (subs[i].language != null
                        ? tr('Sous-titre ({0})', [subs[i].language])
                        : tr('Sous-titre {0}', [i + 1])),
            selected: subs[i] == current,
            onTap: () {
              controller.selectInternalSubtitle(subs[i]);
              widget.onClose();
            },
          ),
      ]);
    }

    final subtitles = controller.mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[];
    return _sectionList([
      _OnyxMenuOption(
        label: tr('Désactivés'),
        selected: controller.selectedSubtitleLang == null,
        onTap: () {
          controller.setSubtitle(null);
          widget.onClose();
        },
      ),
      for (final track in subtitles)
        () {
          final (title, subtitle) = splitTrackLabel(track.displayName);
          return _OnyxMenuOption(
            label: title,
            subtitle: subtitle,
            // A bitmap track has to be burned into the video while
            // transcoding, so picking it costs a short reload.
            badge: !track.ready
                ? '…'
                : (track.image ? 'image' : null),
            selected: controller.selectedSubtitleLang == track.lang,
            onTap: () {
              controller.setSubtitle(track.lang);
              widget.onClose();
            },
          );
        }(),
    ]);
  }

  Widget _buildSpeed() {
    return _sectionList([
      for (final rate in widget.playbackRates)
        _OnyxMenuOption(
          label: rate == 1.0 ? tr('Normale') : '${_trimRate(rate)}×',
          selected: rate == widget.playbackRate,
          onTap: () {
            widget.onRateChanged(rate);
            widget.onClose();
          },
        ),
    ]);
  }

  Widget _buildDisplay() {
    return _sectionList([
      _OnyxMenuOption(
        label: tr('Original'),
        subtitle: tr('Conserve les proportions'),
        selected: _fit == BoxFit.contain,
        onTap: () => _setFit(BoxFit.contain),
      ),
      _OnyxMenuOption(
        label: tr('Adaptatif'),
        subtitle: tr('Remplit l\'écran, coupe les bords'),
        selected: _fit == BoxFit.cover,
        onTap: () => _setFit(BoxFit.cover),
      ),
    ]);
  }

  /// The one section that stays open after a choice, so the ring has to follow
  /// it: the entry node has just moved to the other row, and without this the
  /// focus would be left on a row that no longer holds it.
  void _setFit(BoxFit fit) {
    setState(() => _fit = fit);
    widget.onFitChanged(fit);
    _focusEntryAfterBuild();
  }

  /// La lecture se met en pause à l'échéance, où qu'elle en soit : la
  /// minuterie suit d'un épisode au suivant. Voir [SleepTimer].
  ///
  /// Le compte en épisodes n'est proposé que devant un épisode : un film n'a
  /// pas de suivant à ne pas lancer.
  Widget _buildSleep() {
    final timer = SleepTimer.instance;
    final remaining = timer.remaining;
    final episodesLeft = timer.episodesLeft;

    return _sectionList([
      _OnyxMenuOption(
        label: tr('Désactivée'),
        selected: !timer.isActive,
        onTap: () {
          timer.cancel();
          widget.onClose();
        },
      ),
      if (widget.episodeNav != null)
        for (final count in SleepTimer.episodeChoices)
          () {
            final selected = timer.episodesChosen == count;
            return _OnyxMenuOption(
              label: count == 1
                  ? tr('À la fin de l’épisode')
                  : tr('Après {0} épisodes', [count]),
              value: selected && episodesLeft != null && episodesLeft < count
                  ? tr('reste {0}', [_sleepEpisodes(episodesLeft)])
                  : null,
              selected: selected,
              onTap: () {
                timer.startEpisodes(count);
                widget.onClose();
              },
            );
          }(),
      for (final choice in SleepTimer.choices)
        () {
          final selected = timer.chosen == choice;
          return _OnyxMenuOption(
            label: _sleepChoiceLabel(choice),
            value: selected && remaining != null
                ? 'reste ${_sleepRemaining(remaining)}'
                : null,
            selected: selected,
            onTap: () {
              timer.start(choice);
              widget.onClose();
            },
          );
        }(),
    ]);
  }

  Widget _buildChapters() {
    final chapters = widget.episodeNav!.chapters;
    final seek = widget.onSeekToAbsolute!;

    return _sectionList([
      for (final chapter in chapters)
        _OnyxMenuOption(
          label: chapter.title.isEmpty ? tr('Chapitre {0}', [chapter.id]) : chapter.title,
          value: _timecode(chapter.startTime),
          selected: false,
          onTap: () {
            widget.onClose();
            seek(chapter.startTime.round());
          },
        ),
    ]);
  }
}
