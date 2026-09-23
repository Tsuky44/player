import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/remote_playback.dart';
import '../../navigation/search_route_observer.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../screens/player/player_screen.dart';
import '../../theme/app_colors.dart';
import '../../utils/poster_url.dart';

/// « Lecture en cours sur un autre appareil » : ce que le compte lit ailleurs,
/// avec de quoi le reprendre ici là où il en est — comme YouTube.
///
/// Reprendre ouvre le lecteur, dont le premier signal met l'autre appareil en
/// pause (voir `server/handlers/playback_handoff.go`).
class RemotePlaybackBanner extends StatefulWidget {
  const RemotePlaybackBanner({super.key});

  @override
  State<RemotePlaybackBanner> createState() => _RemotePlaybackBannerState();
}

class _RemotePlaybackBannerState extends State<RemotePlaybackBanner> {
  static const _pollInterval = Duration(seconds: 10);

  Timer? _timer;
  RemotePlayback? _current;
  final Set<String> _dismissed = {};
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _timer = Timer.periodic(_pollInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<List<RemotePlayback>> _fetch() async {
    final api = Provider.of<AuthProvider>(context, listen: false).apiClient;
    try {
      return await api.getMyRemotePlaybacks();
    } catch (_) {
      return const []; // Serveur plus ancien : pas de reprise, rien d'autre.
    }
  }

  Future<void> _refresh() async {
    if (!mounted || _opening) return;
    // Rien à proposer pendant que le lecteur de cet appareil est ouvert.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    final plays = await _fetch();
    if (!mounted) return;
    final next =
        plays.where((p) => !_dismissed.contains(_dismissKey(p))).firstOrNull;
    setState(() => _current = next);
  }

  String _dismissKey(RemotePlayback p) =>
      '${p.session.sessionId}:${p.session.mediaId}';

  Future<void> _resume() async {
    final shown = _current;
    if (shown == null || _opening) return;
    setState(() => _opening = true);
    // La position d'il y a dix secondes ne suffit pas : on la redemande.
    final fresh = (await _fetch())
            .where((p) => p.session.sessionId == shown.session.sessionId)
            .firstOrNull ??
        shown;
    if (!mounted) return;
    setState(() => _current = null);
    await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      settings: const RouteSettings(name: SearchRouteObserver.playerRouteName),
      builder: (_) => PlayerScreen(
        media: fresh.media,
        resumeAtSeconds: fresh.session.positionSeconds,
      ),
    ));
    if (!mounted) return;
    _opening = false;
    Provider.of<HomeProvider>(context, listen: false).loadHome(silent: true);
    unawaited(_refresh());
  }

  @override
  Widget build(BuildContext context) {
    final play = _current;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: play == null ? const SizedBox.shrink() : _card(context, play),
    );
  }

  Widget _card(BuildContext context, RemotePlayback play) {
    final s = play.session;
    final baseUrl =
        Provider.of<AuthProvider>(context, listen: false).apiClient.baseUrl;
    final poster = cardPosterUrl(s.posterUrl, serverBaseUrl: baseUrl);
    final device =
        s.deviceName.isNotEmpty ? s.deviceName : 'un autre appareil';

    return ConstrainedBox(
      key: ValueKey(_dismissKey(play)),
      constraints: const BoxConstraints(maxWidth: 560),
      child: Material(
        color: AppColors.surfaceElevated,
        elevation: 12,
        shadowColor: Colors.black,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 40,
                      height: 60,
                      child: poster == null
                          ? const ColoredBox(color: AppColors.surfaceHover)
                          : Image.network(
                              poster,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const ColoredBox(
                                  color: AppColors.surfaceHover),
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Lecture en cours sur $device',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          s.headline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (s.detail.isNotEmpty)
                          Text(
                            s.detail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _opening ? null : _resume,
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    label: const Text('Reprendre'),
                  ),
                  IconButton(
                    tooltip: 'Ignorer',
                    onPressed: () => setState(() {
                      _dismissed.add(_dismissKey(play));
                      _current = null;
                    }),
                    icon: const Icon(Icons.close_rounded,
                        color: AppColors.textSecondary, size: 20),
                  ),
                ],
              ),
            ),
            LinearProgressIndicator(
              value: s.progress,
              minHeight: 3,
              color: AppColors.progress,
              backgroundColor: AppColors.border,
            ),
          ],
        ),
      ),
    );
  }
}
