import 'dart:async';
import 'package:flutter/material.dart';
import '../playback/audio_language_gap.dart';
import '../playback/playback_session.dart';
import '../playback/skip_segments.dart';
import '../../../models/models.dart';
import '../../../services/api_client.dart';
import '../../../services/playback_preferences_storage.dart';
import '../../../l10n/tr.dart';

class EpisodeNavigationController extends ChangeNotifier {
  final ApiClient _apiClient;
  final int _episodeId;
  final VoidCallback? onAutoPlay;

  /// Called when the intro has been skipped on its own, the countdown having
  /// run out untouched.
  final VoidCallback? onAutoSkipIntro;

  EpisodeTimestamps? timestamps;
  HomeMediaItem? nextEpisode;

  /// Les langues audio de [nextEpisode], vide quand le serveur ne les connaît
  /// pas. Voir [AudioLanguageGap].
  List<String> nextEpisodeAudioLangs = const [];

  /// La question en cours : l'épisode suivant n'existe pas dans la langue
  /// qu'on suit. Elle tient l'écran comme les deux autres cartes de fin.
  AudioLanguageGap? _languageGap;
  AudioLanguageGap? get languageGap => _languageGap;
  bool get showLanguageGapCard => _languageGap != null;

  /// « Non » a été répondu, ou la carte fermée : plus rien n'enchaîne de
  /// lui-même sur cet épisode. Redemander la suite à la main repose la
  /// question — on a le droit de changer d'avis.
  bool _languageGapDeclined = false;
  bool get languageGapDeclined => _languageGapDeclined;

  /// La même question, posée au lancement : c'est l'épisode qu'on vient
  /// d'ouvrir qui n'existe pas dans la langue qu'on suit.
  AudioLanguageGap? _launchLanguageGap;
  AudioLanguageGap? get launchLanguageGap => _launchLanguageGap;
  bool get showLaunchLanguageCard => _launchLanguageGap != null;

  void askLaunchLanguage(AudioLanguageGap gap) {
    _launchLanguageGap = gap;
    notifyListeners();
  }

  void closeLaunchLanguageCard() {
    if (_launchLanguageGap == null) return;
    _launchLanguageGap = null;
    notifyListeners();
  }

  /// Set when the season that follows is missing from the server.
  ///
  /// It comes with a [nextEpisode] when that episode is the last one available:
  /// the offer is then made one episode early, so the download can run while
  /// the finale plays. See [isSeasonLookahead].
  NextSeason? nextSeason;

  /// Set when this season is not over — the episode after this one exists on
  /// TMDB but not on the server. Mutually exclusive with [nextSeason]: while a
  /// season is still airing, asking for the one after it skips episodes.
  UpcomingEpisode? upcomingEpisode;

  /// A "no thanks" only silences the card for this playback, never for good —
  /// the user may well change their mind on the next run.
  bool _nextSeasonDismissed = false;
  bool _nextSeasonForced = false;
  bool _seasonLookahead = false;
  bool _upcomingDismissed = false;
  bool _upcomingForced = false;

  bool isLoading = true;

  // Dynamic chapters parsed via backend ffprobe
  List<VideoChapter> _chapters = [];

  // The end time (in seconds) to seek to when "Skip Intro" is pressed
  int _introSkipTarget = 0;
  int get introSkipTarget => _introSkipTarget;

  /// Ce que le bouton propose de sauter tant que [showSkipIntro] est vrai.
  /// Tout le reste de l'offre — cible, compte à rebours, gel — est commun au
  /// récap et à l'intro.
  SkipSegment _skipSegment = SkipSegment.intro;
  SkipSegment get skipSegment => _skipSegment;

  List<VideoChapter> get chapters => List.unmodifiable(_chapters);

  /// Last-chapter outro heuristic: credits are often the final MKV chapter.
  static const maxLastChapterOutroSeconds = 300; // 5 minutes

  int _chapterEndSeconds(VideoChapter chapter, {int? mediaDurationSeconds}) {
    final start = chapter.startTime.floor();
    final end = chapter.endTime.ceil();
    if (end > start) return end;
    if (mediaDurationSeconds != null && mediaDurationSeconds > start) {
      return mediaDurationSeconds;
    }
    return start + 1;
  }

  int _chapterDurationSeconds(VideoChapter chapter, {int? mediaDurationSeconds}) {
    final start = chapter.startTime.floor();
    return _chapterEndSeconds(chapter, mediaDurationSeconds: mediaDurationSeconds) - start;
  }

  bool _isInShortLastChapter(int positionSeconds, {int? mediaDurationSeconds}) {
    if (_chapters.isEmpty) return false;

    final last = _chapters.last;
    if (_chapterDurationSeconds(last, mediaDurationSeconds: mediaDurationSeconds) >
        maxLastChapterOutroSeconds) {
      return false;
    }

    final start = last.startTime.floor();
    final end = _chapterEndSeconds(last, mediaDurationSeconds: mediaDurationSeconds);
    return positionSeconds >= start && positionSeconds < end;
  }

  Future<void> refreshChapters() async {
    await _loadChapters();
    notifyListeners();
  }

  /// Which intro-detection path is active for the skip button.
  String get activeSkipSource {
    if (timestamps != null && timestamps!.isPlausibleIntro()) {
      return tr('Base de données');
    }
    if (_bestIntroFromChapters() != null) return tr('Chapitres MKV');
    return tr('Aucune');
  }

  bool isIntroChapter(VideoChapter chapter) => ChapterTitles.isIntro(chapter.title);
  bool isOutroChapter(VideoChapter chapter, {int? mediaDurationSeconds}) {
    if (ChapterTitles.isOutro(chapter.title)) return true;
    if (_chapters.isEmpty || chapter.id != _chapters.last.id) return false;
    return _chapterDurationSeconds(chapter, mediaDurationSeconds: mediaDurationSeconds) <=
        maxLastChapterOutroSeconds;
  }

  bool isInsideChapter(VideoChapter chapter, int positionSeconds) {
    return positionSeconds >= chapter.startTime.floor() &&
        positionSeconds < chapter.endTime.ceil();
  }

  // UI States
  bool showSkipIntro = false;
  bool showNextEpisodeOutro = false;
  bool outroAutoPlayActive = false;
  bool outroAutoPlayFrozen = false;

  /// Whether the intro is counting down to skipping itself. Only ever true when
  /// the preference is on and the skip button just came up.
  bool introAutoSkipActive = false;

  /// Set the moment anything is touched during that countdown. Like the outro's
  /// own freeze it never thaws: someone is watching, and the intro they are
  /// watching is not one to jump over behind their back.
  bool introAutoSkipFrozen = false;

  // Timer for outro auto-play
  Timer? _outroTimer;
  int _outroCountdownSeconds = 10;
  int get outroCountdownSeconds => _outroCountdownSeconds;

  /// Same delay as the next episode, so both countdowns read as one behaviour.
  static const int autoSkipIntroSeconds = 5;

  Timer? _introTimer;
  int _introCountdownSeconds = autoSkipIntroSeconds;
  int get introCountdownSeconds => _introCountdownSeconds;

  /// How long the running countdown lasts, for the pill that fills over it.
  /// Null when nothing is counting down, frozen included.
  Duration? get introAutoSkipCountdown =>
      introAutoSkipActive && !introAutoSkipFrozen
          ? const Duration(seconds: autoSkipIntroSeconds)
          : null;

  /// The intro has skipped itself and the seek has not landed yet. Position
  /// ticks keep reporting the intro meanwhile — several seconds of them when
  /// the seek rebuilds an HLS session — and each would bring the pill back
  /// with a fresh countdown.
  SkipSegment? _autoSkippedSegment;

  EpisodeNavigationController({
    required ApiClient apiClient,
    required int episodeId,
    EpisodeTimestamps? initialTimestamps,
    PlaybackSession? session,
    this.onAutoPlay,
    this.onAutoSkipIntro,
  })  : _apiClient = apiClient,
        _episodeId = episodeId {
    if (initialTimestamps != null) {
      timestamps = initialTimestamps;
    }
  }

  Future<void> load() async {
    isLoading = true;
    notifyListeners();

    if (timestamps != null &&
        timestamps!.hasIntro &&
        !timestamps!.isPlausibleIntro()) {
      timestamps = EpisodeTimestamps(
        introStart: 0,
        introEnd: 0,
        outroStart: timestamps!.outroStart,
        outroEnd: timestamps!.outroEnd,
      );
    }

    // 1. Load timestamps from DB (IntroDB / detection). Always refresh from the
    // API so resume-from-home (which omits intro fields) still gets skip data.
    try {
      final fromApi = await _apiClient.getEpisodeTimestamps(_episodeId);
      if (fromApi.hasIntro || fromApi.hasOutro) {
        timestamps = fromApi;
      } else if (timestamps == null ||
          (!timestamps!.hasIntro && !timestamps!.hasOutro)) {
        timestamps = fromApi;
      }
      if (timestamps != null &&
          timestamps!.hasIntro &&
          !timestamps!.isPlausibleIntro()) {
        timestamps = EpisodeTimestamps(
          introStart: 0,
          introEnd: 0,
          outroStart: timestamps!.outroStart,
          outroEnd: timestamps!.outroEnd,
        );
      }
    } catch (e) {
      debugPrint("EpisodeNav: Failed to load timestamps from API: $e");
      timestamps ??= EpisodeTimestamps(
        introStart: 0,
        introEnd: 0,
        outroStart: 0,
        outroEnd: 0,
      );
    }

    // 2. Load next episode info
    try {
      final response = await _apiClient.getNextEpisode(_episodeId);
      if (response.hasNext) {
        nextEpisode = response.episode;
        nextEpisodeAudioLangs = response.episodeAudioLangs;
      }
      nextSeason = response.nextSeason;
      upcomingEpisode = response.upcomingEpisode;
      // Offered early only while it can still be acted on: a season already
      // requested would just interrupt the finale for nothing.
      _seasonLookahead =
          nextEpisode != null && (nextSeason?.canRequest ?? false);
    } catch (e) {
      debugPrint("EpisodeNav: Failed to load next episode: $e");
    }

    // 3. Load dynamic MKV chapters from backend ffprobe (preferred, highly accurate)
    await _loadChapters();

    isLoading = false;
    notifyListeners();
  }

  Future<void> _loadChapters() async {
    try {
      final list = await _apiClient.getEpisodeChapters(_episodeId);
      if (list.isEmpty) return;
      _chapters = list..sort((a, b) => a.startTime.compareTo(b.startTime));
    } catch (e) {
      debugPrint("EpisodeNav: Error loading chapters: $e");
    }
  }

  static bool _isPlausibleIntroRange(int start, int end, {int? mediaDurationSeconds}) {
    return EpisodeTimestamps(
      introStart: start,
      introEnd: end,
      outroStart: 0,
      outroEnd: 0,
    ).isPlausibleIntro(mediaDurationSeconds: mediaDurationSeconds);
  }

  ({int start, int end})? _bestIntroFromChapters({int? mediaDurationSeconds}) =>
      _firstPlausibleChapter(ChapterTitles.isIntro,
          mediaDurationSeconds: mediaDurationSeconds);

  ({int start, int end})? _recapFromChapters({int? mediaDurationSeconds}) =>
      _firstPlausibleChapter(ChapterTitles.isRecap,
          mediaDurationSeconds: mediaDurationSeconds);

  /// Le passage à sauter sous [positionSeconds], et où il finit.
  ///
  /// Le récap vient des chapitres seulement : ni TheIntroDB ni la détection du
  /// serveur ne le rangent à part. L'intro de la base ne compte que si elle
  /// déborde du récap : une ligne qui ne couvre que lui — fusion TheIntroDB,
  /// ou chapitre « Recap » rangé comme intro avant que le serveur ne les
  /// distingue — n'a pas d'intro à offrir, et ce sont alors les chapitres qui
  /// la donnent.
  ({SkipSegment kind, int end})? _skipSegmentAt(
    int positionSeconds, {
    int? mediaDurationSeconds,
  }) {
    bool inside(({int start, int end}) r) =>
        positionSeconds >= r.start && positionSeconds < r.end;

    final recap = _recapFromChapters(mediaDurationSeconds: mediaDurationSeconds);
    if (recap != null && inside(recap)) {
      return (kind: SkipSegment.recap, end: recap.end);
    }

    final db = timestamps;
    final dbIntro = db != null &&
            db.isPlausibleIntro(mediaDurationSeconds: mediaDurationSeconds) &&
            (recap == null || db.introEnd > recap.end)
        ? (start: db.introStart, end: db.introEnd)
        : null;
    final intro = dbIntro ??
        _bestIntroFromChapters(mediaDurationSeconds: mediaDurationSeconds);
    if (intro != null && inside(intro)) {
      return (kind: SkipSegment.intro, end: intro.end);
    }
    return null;
  }

  ({int start, int end})? _firstPlausibleChapter(
    bool Function(String title) matches, {
    int? mediaDurationSeconds,
  }) {
    ({int start, int end})? best;
    for (final c in _chapters) {
      if (!matches(c.title)) continue;
      final start = c.startTime.floor();
      final end = c.endTime.ceil();
      if (!_isPlausibleIntroRange(start, end, mediaDurationSeconds: mediaDurationSeconds)) {
        continue;
      }
      if (best == null || start < best.start) {
        best = (start: start, end: end);
      }
    }
    return best;
  }

  /// [pictureShown] est faux tant que le flux s'ouvre derrière son cache : le
  /// lecteur rapporte déjà la seconde 0 à ce moment-là. Une intro qui ouvre
  /// l'épisode armait alors son compte à rebours pendant le chargement, et le
  /// saut partait vers un flux pas encore prêt à le recevoir — perdu, et
  /// l'intro marquée comme déjà passée. Rien ne se propose avant l'image.
  void checkPosition(
    int positionSeconds, {
    int? mediaDurationSeconds,
    bool pictureShown = true,
  }) {
    if (!pictureShown) return;
    bool inOutro = false;
    final segment = _skipSegmentAt(
      positionSeconds,
      mediaDurationSeconds: mediaDurationSeconds,
    );

    if (timestamps != null && timestamps!.hasOutro) {
      inOutro = positionSeconds >= timestamps!.outroStart &&
          positionSeconds < timestamps!.outroEnd;
    } else if (_chapters.isNotEmpty) {
      for (final c in _chapters) {
        final within = positionSeconds >= c.startTime.floor() &&
            positionSeconds < _chapterEndSeconds(c, mediaDurationSeconds: mediaDurationSeconds);
        if (!within) continue;
        if (ChapterTitles.isOutro(c.title)) {
          inOutro = true;
          break;
        }
      }
      if (!inOutro) {
        inOutro = _isInShortLastChapter(
          positionSeconds,
          mediaDurationSeconds: mediaDurationSeconds,
        );
      }
    }

    if (segment?.kind != _autoSkippedSegment) _autoSkippedSegment = null;

    if (segment == null) {
      if (showSkipIntro) {
        showSkipIntro = false;
        _cancelIntroAutoSkip();
        notifyListeners();
      }
    } else if (segment.kind == _autoSkippedSegment) {
      // Already skipped, still seeking: nothing to offer.
    } else if (!showSkipIntro || segment.kind != _skipSegment) {
      // Un récap regardé jusqu'au bout débouche sur l'intro : c'est une autre
      // proposition, avec son propre réglage et son propre compte à rebours.
      _cancelIntroAutoSkip();
      showSkipIntro = true;
      _skipSegment = segment.kind;
      _introSkipTarget = segment.end;
      // The countdown starts with the button, not with the intro: the two
      // appear together, so what is on screen always says how long is left.
      _startIntroAutoSkip();
      notifyListeners();
    } else if (_introSkipTarget != segment.end) {
      // A better target for the same intro — the countdown already running
      // keeps running, it is the same offer.
      _introSkipTarget = segment.end;
      notifyListeners();
    }

    if (inOutro != showNextEpisodeOutro) {
      showNextEpisodeOutro = inOutro;
      // An end card takes the outro over when it is up: auto-advancing out of
      // a page that asks a question would answer it for the user.
      // Once either card is up it stays up until answered: an outro followed
      // by a teaser would otherwise pull it away mid-decision.
      if (inOutro && isSeasonLookahead && !_nextSeasonDismissed) {
        _nextSeasonForced = true;
      }
      if (inOutro && upcomingEpisode != null && !_upcomingDismissed) {
        _upcomingForced = true;
      }
      if (inOutro &&
          nextEpisode != null &&
          !showEndCard &&
          !_languageGapDeclined) {
        _startOutroAutoPlay();
      } else {
        _cancelOutroAutoPlay();
      }
      notifyListeners();
    }
  }

  /// Retient le passage à l'épisode suivant quand il lui manque la langue
  /// qu'on suit, et lève la carte qui pose la question. Rend vrai tant que
  /// l'enchaînement ne doit pas se faire.
  ///
  /// [automatic] pour un enchaînement que personne n'a demandé — compte à
  /// rebours, fin du fichier : après un « non », il ne repose pas la question.
  bool holdForLanguageGap(AudioLanguageGap? gap, {required bool automatic}) {
    if (gap == null) return false;
    if (_languageGap != null) return true;
    if (_languageGapDeclined && automatic) return true;
    _languageGap = gap;
    _cancelOutroAutoPlay();
    notifyListeners();
    return true;
  }

  /// Range la carte sans enchaîner. Ce que ce refus vaut pour la suite de la
  /// série — attendre sa langue — est l'affaire de l'écran, pas la sienne.
  void declineLanguageGap() {
    if (_languageGap == null) return;
    _languageGap = null;
    _languageGapDeclined = true;
    notifyListeners();
  }

  /// Arms the countdown that skips the intro — or the recap — by itself. Does
  /// nothing unless that segment's preference is on: the button then simply
  /// waits to be pressed.
  void _startIntroAutoSkip() {
    final enabled = switch (_skipSegment) {
      SkipSegment.recap => PlaybackPreferencesStorage.autoSkipRecap,
      SkipSegment.intro => PlaybackPreferencesStorage.autoSkipIntro,
    };
    if (!enabled) return;
    introAutoSkipActive = true;
    introAutoSkipFrozen = false;
    _introCountdownSeconds = autoSkipIntroSeconds;
    _introTimer?.cancel();
    _introTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _introCountdownSeconds--;
      if (_introCountdownSeconds <= 0) {
        timer.cancel();
        introAutoSkipActive = false;
        showSkipIntro = false;
        _autoSkippedSegment = _skipSegment;
        onAutoSkipIntro?.call();
        notifyListeners();
        return;
      }
      notifyListeners();
    });
  }

  void _cancelIntroAutoSkip() {
    introAutoSkipActive = false;
    introAutoSkipFrozen = false;
    _introTimer?.cancel();
    _introTimer = null;
    _introCountdownSeconds = autoSkipIntroSeconds;
  }

  void _startOutroAutoPlay() {
    outroAutoPlayActive = true;
    outroAutoPlayFrozen = false;
    _outroCountdownSeconds = 5;
    _outroTimer?.cancel();
    _outroTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _outroCountdownSeconds--;
      if (_outroCountdownSeconds <= 0) {
        timer.cancel();
        outroAutoPlayActive = false;
        onAutoPlay?.call();
        return; // Don't notify - widget is already destroyed
      }
      notifyListeners();
    });
  }

  /// True when the missing season is offered one episode early: a next episode
  /// exists, and it is the last one the server holds.
  ///
  /// Decided once, when the episode loads, so sending the request — which turns
  /// [NextSeason.canRequest] off — does not yank the card away mid-confirmation.
  bool get isSeasonLookahead => _seasonLookahead;

  /// Whether the end-of-season card should be on screen. It has no countdown
  /// and never acts on its own — requesting a season is always a deliberate tap.
  ///
  /// The upcoming-episode card wins when both could apply: the server sends one
  /// or the other, and a season still airing is not one to look past.
  bool get showNextSeasonCard =>
      (showNextEpisodeOutro || _nextSeasonForced) &&
      nextSeason != null &&
      upcomingEpisode == null &&
      (nextEpisode == null || isSeasonLookahead) &&
      !_nextSeasonDismissed;

  /// Whether the "not out yet" card should be on screen. Purely informative:
  /// there is no per-episode request to send, only a date to state.
  bool get showUpcomingEpisodeCard =>
      (showNextEpisodeOutro || _upcomingForced) &&
      upcomingEpisode != null &&
      !_upcomingDismissed;

  /// Whether either end card owns the screen. Both shrink the video, suppress
  /// the chrome and hold auto-advance back, so the session asks this one thing.
  bool get showEndCard =>
      showNextSeasonCard ||
      showUpcomingEpisodeCard ||
      showLanguageGapCard ||
      showLaunchLanguageCard;

  /// Forces the card up when playback reached the very end without the outro
  /// ever being detected, so a missing chapter marker cannot swallow the offer.
  /// Returns whether the card is now on screen — false means the caller is free
  /// to move on, having been dismissed or having nothing to show.
  ///
  /// Kept separate from [showNextEpisodeOutro], which the position loop owns
  /// and rewrites on every tick.
  bool revealNextSeasonCard() {
    if (nextSeason == null || _nextSeasonDismissed) return false;
    if (upcomingEpisode != null) return false;
    if (nextEpisode != null && !isSeasonLookahead) return false;
    if (!_nextSeasonForced) {
      _nextSeasonForced = true;
      notifyListeners();
    }
    return true;
  }

  /// Same as [revealNextSeasonCard], for the episode the season still awaits.
  bool revealUpcomingEpisodeCard() {
    if (upcomingEpisode == null || _upcomingDismissed) return false;
    if (!_upcomingForced) {
      _upcomingForced = true;
      notifyListeners();
    }
    return true;
  }

  void dismissNextSeasonCard() {
    _nextSeasonDismissed = true;
    // Putting the card away mid-outro hands the outro back to the next-episode
    // pill, countdown included — the behaviour of any other episode.
    if (showNextEpisodeOutro && nextEpisode != null && !showEndCard) {
      _startOutroAutoPlay();
    }
    notifyListeners();
  }

  void dismissUpcomingEpisodeCard() {
    _upcomingDismissed = true;
    if (showNextEpisodeOutro && nextEpisode != null && !showEndCard) {
      _startOutroAutoPlay();
    }
    notifyListeners();
  }

  /// Flips the card to its confirmed state after a request went through.
  void markNextSeasonRequested() {
    final season = nextSeason;
    if (season == null) return;
    nextSeason = season.copyWith(requestStatus: 'pending', canRequest: false);
    notifyListeners();
  }

  void _cancelOutroAutoPlay() {
    outroAutoPlayActive = false;
    outroAutoPlayFrozen = false;
    _outroTimer?.cancel();
    _outroCountdownSeconds = 5;
  }

  /// Any sign of someone at the controls — a mouse moved, a key or a remote
  /// button pressed, the picture tapped. Both countdowns stop where they are:
  /// they exist for the viewer who has left the room, not the one watching.
  void onUserActivity() {
    var changed = false;

    if (outroAutoPlayActive && !outroAutoPlayFrozen && nextEpisode != null) {
      outroAutoPlayFrozen = true;
      _outroTimer?.cancel();
      changed = true;
    }

    if (introAutoSkipActive && !introAutoSkipFrozen) {
      introAutoSkipFrozen = true;
      _introTimer?.cancel();
      _introTimer = null;
      changed = true;
    }

    if (changed) notifyListeners();
  }

  void skipIntro() {
    showSkipIntro = false;
    _cancelIntroAutoSkip();
    notifyListeners();
  }

  void cancelAutoPlay() {
    _cancelOutroAutoPlay();
    showNextEpisodeOutro = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _outroTimer?.cancel();
    _introTimer?.cancel();
    super.dispose();
  }
}
