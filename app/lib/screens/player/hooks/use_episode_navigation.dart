import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import '../../../models/models.dart';
import '../../../services/api_client.dart';

class EpisodeNavigationController extends ChangeNotifier {
  final ApiClient _apiClient;
  final int _episodeId;
  final VoidCallback? onAutoPlay;

  EpisodeTimestamps? timestamps;
  HomeMediaItem? nextEpisode;
  bool isLoading = true;

  // Dynamic chapters parsed via backend ffprobe
  List<VideoChapter> _chapters = [];

  // The end time (in seconds) to seek to when "Skip Intro" is pressed
  int _introSkipTarget = 0;
  int get introSkipTarget => _introSkipTarget;

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
      return 'Base de données';
    }
    if (_bestIntroFromChapters() != null) return 'Chapitres MKV';
    return 'Aucune';
  }

  bool isIntroChapter(VideoChapter chapter) => _isIntroTitle(chapter.title);
  bool isOutroChapter(VideoChapter chapter, {int? mediaDurationSeconds}) {
    if (_isOutroTitle(chapter.title)) return true;
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

  // Timer for outro auto-play
  Timer? _outroTimer;
  int _outroCountdownSeconds = 10;
  int get outroCountdownSeconds => _outroCountdownSeconds;

  EpisodeNavigationController({
    required ApiClient apiClient,
    required int episodeId,
    EpisodeTimestamps? initialTimestamps,
    mk.Player? player,
    this.onAutoPlay,
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
      print("EpisodeNav: Failed to load timestamps from API: $e");
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
      }
    } catch (e) {
      print("EpisodeNav: Failed to load next episode: $e");
    }

    // 3. Load dynamic MKV chapters from backend ffprobe (preferred, highly accurate)
    await _loadChapters();

    isLoading = false;
    notifyListeners();
  }

  Future<void> _loadChapters() async {
    try {
      final list = await _apiClient.getEpisodeChapters(_episodeId);
      if (list.isEmpty) {
        print("EpisodeNav: No chapters returned from backend ffprobe.");
        return;
      }

      _chapters = list..sort((a, b) => a.startTime.compareTo(b.startTime));
      print("EpisodeNav: Successfully loaded ${_chapters.length} chapters from backend!");
      for (final c in _chapters) {
        print("EpisodeNav: chapter '${c.title}' [${c.startTime} -> ${c.endTime}]");
      }
    } catch (e) {
      print("EpisodeNav: Error loading chapters: $e");
    }
  }

  static String _normalizeChapterTitle(String title) {
    const accents = {
      'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
      'à': 'a', 'â': 'a', 'ä': 'a',
      'î': 'i', 'ï': 'i',
      'ô': 'o', 'ö': 'o',
      'û': 'u', 'ü': 'u', 'ù': 'u',
      'ç': 'c',
    };
    var t = title.toLowerCase().trim();
    accents.forEach((from, to) {
      t = t.replaceAll(from, to);
    });
    return t;
  }

  static bool _titleMatchesKeyword(String normTitle, String keyword) {
    if (keyword == 'op' || keyword == 'ed') {
      if (normTitle == keyword) return true;
      return normTitle.startsWith('$keyword ') || normTitle.endsWith(' $keyword');
    }
    return normTitle.contains(keyword);
  }

  static bool _isOpeningCreditsTitle(String t) {
    if (t.contains('opencreditstart') || t.contains('open_credit_start')) {
      return true;
    }
    if (t.contains('open') && t.contains('credit') && t.contains('start')) {
      return true;
    }
    if (t.contains('opening') && t.contains('credit')) return true;
    return false;
  }

  static bool _isClosingCreditsTitle(String t) {
    if (_isOpeningCreditsTitle(t)) return false;
    if (t.contains('open') && t.contains('credit')) return false;
    if (t == 'credits' || t == 'credit') return true;
    if (t.contains('credits')) return true;
    return false;
  }

  static bool _isIntroTitle(String title) {
    final t = _normalizeChapterTitle(title);
    if (t.isEmpty) return false;
    if (_isOpeningCreditsTitle(t)) return true;
    const keywords = [
      'intro', 'opening', 'recap', 'previously on',
      'generique de debut', 'generique debut',
    ];
    for (final kw in keywords) {
      if (_titleMatchesKeyword(t, kw)) return true;
    }
    return _titleMatchesKeyword(t, 'op');
  }

  static bool _isOutroTitle(String title) {
    final t = _normalizeChapterTitle(title);
    if (t.isEmpty) return false;
    if (_isClosingCreditsTitle(t)) return true;
    const keywords = [
      'outro', 'ending',
      'generique de fin', 'generique fin',
    ];
    for (final kw in keywords) {
      if (_titleMatchesKeyword(t, kw)) return true;
    }
    return _titleMatchesKeyword(t, 'ed');
  }

  static bool _isPlausibleIntroRange(int start, int end, {int? mediaDurationSeconds}) {
    return EpisodeTimestamps(
      introStart: start,
      introEnd: end,
      outroStart: 0,
      outroEnd: 0,
    ).isPlausibleIntro(mediaDurationSeconds: mediaDurationSeconds);
  }

  ({int start, int end})? _bestIntroFromChapters({int? mediaDurationSeconds}) {
    ({int start, int end})? best;
    for (final c in _chapters) {
      if (!_isIntroTitle(c.title)) continue;
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

  void checkPosition(int positionSeconds, {int? mediaDurationSeconds}) {
    bool inIntro = false;
    bool inOutro = false;
    int introTarget = 0;

    final dbIntro = timestamps != null &&
        timestamps!.isPlausibleIntro(mediaDurationSeconds: mediaDurationSeconds);

    if (dbIntro) {
      inIntro = positionSeconds >= timestamps!.introStart &&
          positionSeconds < timestamps!.introEnd;
      if (inIntro) introTarget = timestamps!.introEnd;
    } else {
      final chapterIntro = _bestIntroFromChapters(mediaDurationSeconds: mediaDurationSeconds);
      if (chapterIntro != null) {
        inIntro = positionSeconds >= chapterIntro.start &&
            positionSeconds < chapterIntro.end;
        if (inIntro) introTarget = chapterIntro.end;
      }
    }

    if (timestamps != null && timestamps!.hasOutro) {
      inOutro = positionSeconds >= timestamps!.outroStart &&
          positionSeconds < timestamps!.outroEnd;
    } else if (_chapters.isNotEmpty) {
      for (final c in _chapters) {
        final within = positionSeconds >= c.startTime.floor() &&
            positionSeconds < _chapterEndSeconds(c, mediaDurationSeconds: mediaDurationSeconds);
        if (!within) continue;
        if (_isOutroTitle(c.title)) {
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

    if (inIntro) {
      if (!showSkipIntro || _introSkipTarget != introTarget) {
        showSkipIntro = true;
        _introSkipTarget = introTarget;
        notifyListeners();
      }
    } else if (showSkipIntro) {
      showSkipIntro = false;
      notifyListeners();
    }

    if (inOutro != showNextEpisodeOutro) {
      showNextEpisodeOutro = inOutro;
      if (inOutro && nextEpisode != null) {
        _startOutroAutoPlay();
      } else {
        _cancelOutroAutoPlay();
      }
      notifyListeners();
    }
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

  void _cancelOutroAutoPlay() {
    outroAutoPlayActive = false;
    outroAutoPlayFrozen = false;
    _outroTimer?.cancel();
    _outroCountdownSeconds = 5;
  }

  void onMouseMove() {
    if (outroAutoPlayActive && !outroAutoPlayFrozen && nextEpisode != null) {
      outroAutoPlayFrozen = true;
      _outroTimer?.cancel();
      notifyListeners();
    }
  }

  void skipIntro() {
    showSkipIntro = false;
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
    super.dispose();
  }
}
