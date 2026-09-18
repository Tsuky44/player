import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/models.dart';
import '../../../models/server_activity.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../playback_logs_screen.dart';
import '../widgets/history_tile.dart';
import '../widgets/settings_ui.dart';

class ActivityPage extends StatefulWidget {
  const ActivityPage({super.key});

  @override
  State<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends State<ActivityPage> {
  static const _pageSize = 50;

  final List<PlaybackHistoryEntry> _entries = [];
  List<User> _users = const [];
  int? _userFilter;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
    context.read<ApiClient>().getUsers().then((users) {
      if (mounted) setState(() => _users = users);
    }).catchError((_) {});
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await context
          .read<ApiClient>()
          .getPlaybackHistory(limit: _pageSize, userId: _userFilter);
      if (!mounted) return;
      setState(() {
        _entries
          ..clear()
          ..addAll(entries);
        _hasMore = entries.length == _pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = settingsErrorText(e, 'Impossible de charger l’historique.');
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _entries.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final entries = await context.read<ApiClient>().getPlaybackHistory(
            limit: _pageSize,
            userId: _userFilter,
            beforeId: _entries.last.id,
          );
      if (!mounted) return;
      setState(() {
        _entries.addAll(entries);
        _hasMore = entries.length == _pageSize;
      });
    } catch (_) {}
    if (mounted) setState(() => _loadingMore = false);
  }

  Future<void> _clear() async {
    final confirmed = await confirmSettingsAction(
      context,
      title: 'Vider l’historique ?',
      message:
          'Toutes les lectures enregistrées et les statistiques qui en découlent seront effacées, pour tous les utilisateurs. La progression de lecture n’est pas touchée.',
      confirmLabel: 'Vider',
    );
    if (!confirmed || !mounted) return;
    try {
      await context.read<ApiClient>().clearPlaybackHistory();
      if (mounted) showSettingsSnack(context, 'Historique vidé.');
    } catch (e) {
      if (mounted) {
        showSettingsSnack(context, settingsErrorText(e, 'Échec.'), error: true);
      }
    }
    _reload();
  }

  String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Aujourd’hui';
    if (diff == 1) return 'Hier';
    return formatFrenchDay(day, capitalize: true);
  }

  @override
  Widget build(BuildContext context) {
    // Grouped by local day, newest first — the list already comes sorted.
    final groups = <DateTime, List<PlaybackHistoryEntry>>{};
    for (final entry in _entries) {
      final day = DateTime(
          entry.startedAt.year, entry.startedAt.month, entry.startedAt.day);
      groups.putIfAbsent(day, () => []).add(entry);
    }

    return SettingsPage(
      title: 'Historique',
      description:
          'Chaque lecture de plus de 30 secondes : le titre, le compte, l’appareil et le temps réellement regardé, '
          'pauses exclues. Touchez une ligne pour lire le journal du lecteur — celles qui ont échoué y figurent aussi, '
          'quelle qu’ait été leur durée.',
      onRefresh: _reload,
      actions: [
        PopupMenuButton<String>(
          tooltip: 'Plus',
          color: AppColors.surfaceElevated,
          icon: const Icon(Icons.more_horiz_rounded),
          onSelected: (_) => _clear(),
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'clear',
              child: Text('Vider l’historique',
                  style: TextStyle(color: AppColors.error)),
            ),
          ],
        ),
      ],
      children: [
        if (_users.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _FilterChip(
                    label: 'Tout le monde',
                    selected: _userFilter == null,
                    onTap: () {
                      setState(() => _userFilter = null);
                      _reload();
                    },
                  ),
                  for (final user in _users)
                    _FilterChip(
                      label: user.username,
                      avatar: UserAvatar(user.username, size: 18),
                      selected: _userFilter == user.id,
                      onTap: () {
                        setState(() => _userFilter = user.id);
                        _reload();
                      },
                    ),
                ],
              ),
            ),
          ),
        if (_error != null) SettingsBanner(_error!, tone: BannerTone.error),
        if (_loading)
          const SettingsLoading()
        else if (_entries.isEmpty && _error == null)
          const SettingsGroup(children: [
            SettingsEmptyNote(
              'Aucune lecture enregistrée. L’historique se remplit dès qu’un appareil à jour lit un média.',
              icon: Icons.history_toggle_off_rounded,
            ),
          ])
        else ...[
          for (final day in groups.keys)
            SettingsGroup(
              title: _dayLabel(day),
              trailing: Text(
                formatWatchTime(groups[day]!
                    .fold<int>(0, (sum, e) => sum + e.watchedSeconds)),
                style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
              children: [
                for (final entry in groups[day]!)
                  HistoryTile(
                    entry,
                    showUser: _userFilter == null,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PlaybackLogsScreen(entry),
                      ),
                    ),
                  ),
              ],
            ),
          if (_hasMore)
            Center(
              child: _loadingMore
                  ? const SettingsLoading()
                  : OutlinedButton.icon(
                      onPressed: _loadMore,
                      icon: const Icon(Icons.expand_more_rounded),
                      label: const Text('Charger plus'),
                    ),
            ),
        ],
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.avatar,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? avatar;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        avatar: avatar,
        selected: selected,
        showCheckmark: false,
        onSelected: (_) => onTap(),
        selectedColor: AppColors.primary.withValues(alpha: 0.22),
        side: BorderSide(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.1),
        ),
      ),
    );
  }
}
