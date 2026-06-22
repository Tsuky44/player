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

    // 1. Load static timestamps from DB if not already provided
    if (timestamps == null) {
      try {
        timestamps = await _apiClient.getEpisodeTimestamps(_episodeId);
      } catch (e) {
        print("EpisodeNav: Failed to load timestamps from API: $e");
        timestamps = EpisodeTimestamps(introStart: 0, introEnd: 0, outroStart: 0, outroEnd: 0);
      }
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

  static bool _isIntroTitle(String title) {
    final t = title.toLowerCase().trim();
    return t.contains('intro') ||
        t.contains('opening') ||
        t.contains('g\u00e9n\u00e9rique d\u00e9but') ||
        t == 'op' ||
        t.startsWith('op ');
  }

  static bool _isOutroTitle(String title) {
    final t = title.toLowerCase().trim();
    return t.contains('outro') ||
        t.contains('ending') ||
        t.contains('credits') ||
        t.contains('g\u00e9n\u00e9rique fin') ||
        t == 'ed' ||
        t.startsWith('ed ');
  }

  void checkPosition(int positionSeconds) {
    bool inIntro = false;
    bool inOutro = false;
    int introTarget = 0;

    // Prefer DB timestamps (audio correlation detection) over chapters
    if (timestamps != null && timestamps!.hasIntro) {
      inIntro = positionSeconds >= timestamps!.introStart &&
          positionSeconds < timestamps!.introEnd;
      if (inIntro) introTarget = timestamps!.introEnd;
    } else if (_chapters.isNotEmpty) {
      // Chapter-based detection (fallback if no DB timestamps)
      for (final c in _chapters) {
        final within = positionSeconds >= c.startTime.floor() && positionSeconds < c.endTime.ceil();
        if (!within) continue;
        if (_isIntroTitle(c.title)) {
          inIntro = true;
          introTarget = c.endTime.floor();
        }
      }
    }

    if (timestamps != null && timestamps!.hasOutro) {
      inOutro = positionSeconds >= timestamps!.outroStart &&
          positionSeconds < timestamps!.outroEnd;
    } else if (_chapters.isNotEmpty) {
      // Chapter-based detection for outro (fallback)
      for (final c in _chapters) {
        final within = positionSeconds >= c.startTime.floor() && positionSeconds < c.endTime.ceil();
        if (!within) continue;
        if (_isOutroTitle(c.title)) {
          inOutro = true;
        }
      }
    }

    if (inIntro != showSkipIntro) {
      showSkipIntro = inIntro;
      if (inIntro) _introSkipTarget = introTarget;
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
