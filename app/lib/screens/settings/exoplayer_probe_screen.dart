import 'dart:async';

import 'package:flutter/material.dart';
import 'package:onyx_player_android/onyx_player_android.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_focus.dart';

/// Banc d'essai du lecteur ExoPlayer — **temporaire, à supprimer**.
///
/// Il n'existe que pour répondre à une question, et une seule : est-ce qu'une
/// image 4K passe mieux par une `SurfaceView` que par le rendu GPU de mpv ? Il
/// n'a donc ni pistes, ni sous-titres, ni reprise, ni chrome — rien qui
/// pourrait masquer la réponse ou retarder le moment de l'obtenir.
///
/// La réponse est le compteur d'images perdues affiché en bas, à comparer au
/// `frame-drop-count` que le lecteur mpv journalise en sortie sur le même
/// fichier. En dessous de 50 % d'images perdues en moins, le portage échoue et
/// on s'arrête — c'est convenu d'avance, précisément pour que le coût déjà
/// engagé ne décide pas à notre place.
///
/// Rien ici ne doit servir de base au vrai portage : le lecteur définitif est
/// piloté par le contrôleur partagé, pas par un écran.
class ExoPlayerProbeScreen extends StatefulWidget {
  const ExoPlayerProbeScreen({super.key});

  @override
  State<ExoPlayerProbeScreen> createState() => _ExoPlayerProbeScreenState();
}

class _ExoPlayerProbeScreenState extends State<ExoPlayerProbeScreen> {
  OnyxPlayer? _player;
  OnyxPlayerStatus? _status;
  OnyxPlaybackStats? _stats;
  StreamSubscription<OnyxPlayerStatus>? _statusSubscription;
  Timer? _statsTimer;
  String? _openError;
  String? _playingTitle;

  @override
  void dispose() {
    _statsTimer?.cancel();
    unawaited(_statusSubscription?.cancel());
    unawaited(_player?.release());
    super.dispose();
  }

  Future<void> _playMedia(Media media) async {
    final apiClient = context.read<AuthProvider>().apiClient;
    final url = apiClient.getStreamUrl(media.id);

    try {
      final player = _player ?? await OnyxPlayer.create();
      if (!mounted) return;

      if (_player == null) {
        _player = player;
        _statusSubscription = player.statuses.listen((status) {
          if (mounted) setState(() => _status = status);
        });
        // Les compteurs d'images ne sont pas un événement : on les relit.
        _statsTimer = Timer.periodic(
          const Duration(seconds: 1),
          (_) async {
            final stats = await player.stats();
            if (mounted) setState(() => _stats = stats);
          },
        );
      }

      setState(() {
        _openError = null;
        _playingTitle = media.title;
      });
      await player.open(url);
      await player.play();
    } catch (error) {
      if (mounted) setState(() => _openError = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Banc d’essai ExoPlayer'),
        backgroundColor: Colors.transparent,
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (player != null) OnyxPlayerView(playerId: player.id),
                if (player == null)
                  const Center(
                    child: Text(
                      'Choisissez un média ci-dessous.',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
          _readout(),
          if (player != null) _transport(player),
          SizedBox(height: 132, child: _picker()),
        ],
      ),
    );
  }

  /// Le verdict du jalon, en clair.
  Widget _readout() {
    final status = _status;
    final stats = _stats;
    final dropped = stats?.droppedFrames ?? 0;
    final rendered = stats?.renderedFrames ?? 0;
    final ratio = rendered > 0
        ? (dropped / (dropped + rendered) * 100).toStringAsFixed(2)
        : '—';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      color: Colors.white.withValues(alpha: 0.05),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _openError != null
                ? 'Erreur : $_openError'
                : _playingTitle ?? 'Aucun média',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            status == null
                ? 'état : —'
                : 'état : ${status.state.name} · lecture : ${status.isPlaying}'
                    ' · ${_fmt(status.positionMs)} / ${_fmt(status.durationMs)}'
                    '${status.videoSize == null ? '' : ' · '
                        '${status.videoSize!.width}×${status.videoSize!.height}'}',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
          if (status?.errorKind != null)
            Text(
              '${status!.errorKind!.name} — ${status.errorMessage ?? ''}',
              style: const TextStyle(color: AppColors.error, fontSize: 13),
            ),
          const SizedBox(height: 4),
          Text(
            'images perdues : $dropped · rendues : $rendered · $ratio %',
            style: const TextStyle(
              color: AppColors.accentMuted,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _transport(OnyxPlayer player) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _probeButton(Icons.replay_10_rounded, () async {
            final at = _status?.positionMs ?? 0;
            await player.seekTo(Duration(milliseconds: (at - 10000).clamp(0, at)));
          }),
          _probeButton(
            (_status?.isPlaying ?? false)
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
            () => (_status?.isPlaying ?? false) ? player.pause() : player.play(),
          ),
          _probeButton(Icons.forward_10_rounded, () async {
            final at = _status?.positionMs ?? 0;
            await player.seekTo(Duration(milliseconds: at + 10000));
          }),
        ],
      ),
    );
  }

  Widget _probeButton(IconData icon, VoidCallback onPressed) {
    return TvFocusable(
      onSelect: onPressed,
      borderRadius: BorderRadius.circular(24),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, color: Colors.white, size: 30),
      ),
    );
  }

  /// De quoi lancer un fichier sans clavier : ce que l'accueil a déjà chargé.
  Widget _picker() {
    final data = context.watch<HomeProvider>().homeData;
    final items = <Media>[
      if (data != null) ...[
        ...data.continueWatching.map((e) => e.media),
        ...data.recentMovies,
      ],
    ];

    if (items.isEmpty) {
      return const Center(
        child: Text(
          'Rien à lire — ouvrez l’accueil d’abord.',
          style: TextStyle(color: AppColors.textMuted),
        ),
      );
    }

    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(width: 10),
      itemBuilder: (context, index) {
        final media = items[index];
        return TvFocusable(
          onSelect: () => _playMedia(media),
          borderRadius: BorderRadius.circular(10),
          child: Material(
            color: Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              onTap: () => _playMedia(media),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 190,
                padding: const EdgeInsets.all(12),
                alignment: Alignment.centerLeft,
                child: Text(
                  media.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textPrimary),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static String _fmt(int ms) {
    final total = Duration(milliseconds: ms);
    final h = total.inHours;
    final m = total.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = total.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
