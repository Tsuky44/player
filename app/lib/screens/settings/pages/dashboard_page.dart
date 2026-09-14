import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/server_activity.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/format.dart';
import '../widgets/history_tile.dart';
import '../widgets/media_thumb.dart';
import '../widgets/settings_ui.dart';

/// Ce qui se passe sur le serveur, maintenant.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  static const _refreshEvery = Duration(seconds: 5);

  ServerInfo? _server;
  List<NowPlayingSession>? _nowPlaying;
  List<PlaybackHistoryEntry>? _recent;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    // Assez souvent pour suivre une barre de progression, pas au point de
    // charger le serveur : un écran de tableau de bord reste ouvert longtemps.
    _timer = Timer.periodic(_refreshEvery, (_) => _load(live: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool live = false}) async {
    final api = context.read<ApiClient>();
    final canSeeActivity = context.read<AuthProvider>().permissions.manageUsers;
    try {
      final results = await Future.wait<Object?>([
        api.getServerInfo(),
        canSeeActivity ? api.getNowPlaying() : Future.value(null),
        // L'activité récente bouge moins vite que les barres de progression.
        canSeeActivity && (!live || _recent == null)
            ? api.getPlaybackHistory(limit: 6)
            : Future.value(_recent),
      ]);
      if (!mounted) return;
      setState(() {
        _server = results[0] as ServerInfo;
        _nowPlaying = results[1] as List<NowPlayingSession>?;
        _recent = results[2] as List<PlaybackHistoryEntry>?;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = settingsErrorText(
          e, 'Impossible de joindre le tableau de bord du serveur.'));
    }
  }

  String _uptime(int seconds) {
    final days = seconds ~/ 86400;
    final hours = (seconds % 86400) ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (days > 0) return '$days j $hours h';
    if (hours > 0) return '$hours h $minutes min';
    return '$minutes min';
  }

  @override
  Widget build(BuildContext context) {
    final perms = context.watch<AuthProvider>().permissions;
    final server = _server;
    final playing = _nowPlaying;
    final layout = SettingsLayout.maybeOf(context);

    return SettingsPage(
      title: 'Tableau de bord',
      description:
          'L’état du serveur en direct : qui regarde quoi en ce moment, et comment se porte la machine.',
      onRefresh: _load,
      actions: [
        IconButton(
          tooltip: 'Actualiser',
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      children: [
        if (_error != null) SettingsBanner(_error!, tone: BannerTone.error),
        if (server == null && _error == null)
          const SettingsLoading()
        else if (server != null) ...[
          StatGrid(children: [
            StatTile(
              icon: Icons.play_circle_rounded,
              label: 'En lecture',
              value: '${server.nowPlaying}',
              color: server.nowPlaying > 0
                  ? AppColors.success
                  : AppColors.textMuted,
              hint: server.nowPlaying == 0
                  ? 'Personne en ce moment'
                  : 'maintenant',
            ),
            StatTile(
              icon: Icons.bolt_rounded,
              label: 'Transcodages',
              value: '${server.transcodes}',
              color: server.transcodes > 0
                  ? AppColors.warning
                  : AppColors.textMuted,
              hint: 'sessions HLS actives',
            ),
            StatTile(
              icon: Icons.devices_rounded,
              label: 'Appareils actifs',
              value: '${server.activeDevices}',
              hint: 'dernières 24 h',
            ),
            StatTile(
              icon: Icons.group_rounded,
              label: 'Utilisateurs',
              value: '${server.users}',
              color: AppColors.accentMuted,
            ),
          ]),
        ],
        if (perms.manageUsers)
          SettingsGroup(
            title: 'En cours de lecture',
            trailing: const _LiveDot(),
            children: [
              if (playing == null)
                const SettingsLoading()
              else if (playing.isEmpty)
                const SettingsEmptyNote('Aucune lecture en cours.',
                    icon: Icons.nights_stay_outlined)
              else
                for (final session in playing) _NowPlayingCard(session),
            ],
          ),
        if (server != null) ...[
          SettingsGroup(
            title: 'Bibliothèque',
            children: [
              SettingsTile(
                icon: Icons.movie_outlined,
                title:
                    '${server.movies} films · ${server.shows} séries · ${server.episodes} épisodes',
                subtitle:
                    '${formatBytes(server.libraryBytes)} sur disque · ${formatWatchTime(server.libraryDurationSeconds)} de contenu',
                showChevron: false,
                trailing: server.scanning
                    ? const SettingsPill('Analyse en cours',
                        color: AppColors.primary, icon: Icons.sync_rounded)
                    : null,
              ),
            ],
          ),
          SettingsGroup(
            title: 'Serveur',
            children: [
              SettingsTile(
                icon: Icons.timer_outlined,
                title: 'En ligne depuis ${_uptime(server.uptimeSeconds)}',
                subtitle: 'Démarré ${relativeTime(server.startedAt)}',
                showChevron: false,
              ),
              SettingsTile(
                icon: Icons.developer_board_rounded,
                title: '${server.os} · ${server.arch} · ${server.cpus} cœurs',
                subtitle: 'Go ${server.goVersion.replaceFirst('go', '')}',
                showChevron: false,
              ),
              SettingsTile(
                icon: Icons.storage_rounded,
                title: 'Mémoire ${formatBytes(server.memoryBytes)}',
                subtitle:
                    'Base de données ${formatBytes(server.databaseBytes)}',
                showChevron: false,
              ),
            ],
          ),
        ],
        if (perms.manageUsers)
          SettingsGroup(
            title: 'Activité récente',
            trailing: layout == null
                ? null
                : TextButton(
                    onPressed: () => layout.openSection('activity'),
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    child: const Text('Tout l’historique'),
                  ),
            children: [
              if (_recent == null)
                const SettingsLoading()
              else if (_recent!.isEmpty)
                const SettingsEmptyNote(
                    'Rien pour l’instant : l’historique se remplit à chaque lecture.')
              else
                for (final entry in _recent!) HistoryTile(entry),
            ],
          ),
      ],
    );
  }
}

class _LiveDot extends StatefulWidget {
  const _LiveDot();

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeTransition(
          opacity: Tween(begin: 0.35, end: 1.0).animate(_controller),
          child: Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: AppColors.success,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: 6),
        const Text(
          'EN DIRECT',
          style: TextStyle(
            color: AppColors.success,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
        ),
      ],
    );
  }
}

class _NowPlayingCard extends StatelessWidget {
  const _NowPlayingCard(this.session);

  final NowPlayingSession session;

  @override
  Widget build(BuildContext context) {
    final methodColor = playMethodColor(session.playMethod);
    final positions = session.durationSeconds > 0
        ? '${formatPlaybackTime(session.positionSeconds)} / ${formatPlaybackTime(session.durationSeconds)}'
        : formatPlaybackTime(session.positionSeconds);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MediaThumb(
            posterUrl: session.posterUrl,
            width: 58,
            isShow: session.showTitle.isNotEmpty,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        session.headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SettingsPill(
                      session.playMethod.label,
                      color: methodColor,
                    ),
                  ],
                ),
                if (session.detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    session.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12.5),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    UserAvatar(session.username, size: 20),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        [
                          session.username,
                          if (session.deviceName.isNotEmpty) session.deviceName,
                          if (session.client.isNotEmpty) session.client,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 12),
                      ),
                    ),
                    if (session.address.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: session.address,
                        child: Icon(
                          session.isLocal
                              ? Icons.home_rounded
                              : Icons.public_rounded,
                          size: 14,
                          color: session.isLocal
                              ? AppColors.textMuted
                              : AppColors.warning,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      session.paused
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 16,
                      color: session.paused
                          ? AppColors.textMuted
                          : AppColors.textPrimary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(end: session.progress),
                          duration: const Duration(milliseconds: 600),
                          builder: (_, value, __) => LinearProgressIndicator(
                            value: value,
                            minHeight: 4,
                            backgroundColor:
                                Colors.white.withValues(alpha: 0.08),
                            color: session.paused
                                ? AppColors.textMuted
                                : AppColors.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      positions,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11.5,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
