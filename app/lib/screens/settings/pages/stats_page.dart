import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/models.dart';
import '../../../models/server_activity.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../widgets/media_thumb.dart';
import '../widgets/settings_ui.dart';

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  static const _periods = [
    (7, '7 jours'),
    (30, '30 jours'),
    (90, '3 mois'),
    (365, '1 an')
  ];

  int _days = 30;
  int? _userId;
  List<User> _users = const [];
  PlaybackStats? _stats;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    context.read<ApiClient>().getUsers().then((users) {
      if (mounted) setState(() => _users = users);
    }).catchError((_) {});
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final stats = await context
          .read<ApiClient>()
          .getPlaybackStats(days: _days, userId: _userId);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            settingsErrorText(e, 'Impossible de calculer les statistiques.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final perDay = stats == null || stats.days == 0
        ? 0
        : stats.watchedSeconds ~/ stats.days;

    return SettingsPage(
      title: 'Statistiques',
      description:
          'Ce qui se regarde sur le serveur : temps de visionnage, titres préférés, habitudes et applications utilisées.',
      onRefresh: _load,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final (days, label) in _periods)
                ChoiceChip(
                  label: Text(label),
                  selected: _days == days,
                  showCheckmark: false,
                  selectedColor: AppColors.primary.withValues(alpha: 0.2),
                  backgroundColor: Colors.transparent,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                  onSelected: (_) {
                    if (_days == days) return;
                    setState(() => _days = days);
                    _load();
                  },
                ),
              if (_users.length > 1)
                PopupMenuButton<int?>(
                  tooltip: 'Filtrer par utilisateur',
                  color: AppColors.surfaceElevated,
                  onSelected: (id) {
                    setState(() => _userId = id == -1 ? null : id);
                    _load();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: -1, child: Text('Tout le monde')),
                    for (final user in _users)
                      PopupMenuItem(
                        value: user.id,
                        child: Row(children: [
                          UserAvatar(user.username, size: 20),
                          const SizedBox(width: 8),
                          Text(user.username),
                        ]),
                      ),
                  ],
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.person_outline_rounded,
                          size: 16, color: AppColors.textSecondary),
                      const SizedBox(width: 6),
                      Text(_userId == null
                          ? 'Tout le monde'
                          : _users
                                  .where((u) => u.id == _userId)
                                  .map((u) => u.username)
                                  .firstOrNull ??
                              '—'),
                      const Icon(Icons.arrow_drop_down_rounded,
                          color: AppColors.textSecondary),
                    ]),
                  ),
                ),
              if (_loading && stats != null)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
        if (_error != null) SettingsBanner(_error!, tone: BannerTone.error),
        if (stats == null && _loading)
          const SettingsLoading()
        else if (stats != null) ...[
          StatGrid(children: [
            StatTile(
              icon: Icons.schedule_rounded,
              label: 'Temps de visionnage',
              value: formatWatchTime(stats.watchedSeconds),
              hint: '≈ ${formatWatchTime(perDay)} par jour',
            ),
            StatTile(
              icon: Icons.play_arrow_rounded,
              label: 'Lectures',
              value: '${stats.plays}',
              hint:
                  '${stats.activeUsers} utilisateur${stats.activeUsers > 1 ? 's' : ''} actif${stats.activeUsers > 1 ? 's' : ''}',
              color: AppColors.success,
            ),
            StatTile(
              icon: Icons.movie_outlined,
              label: 'Films différents',
              value: '${stats.movies}',
              color: AppColors.warning,
            ),
            StatTile(
              icon: Icons.tv_rounded,
              label: 'Épisodes différents',
              value: '${stats.episodes}',
              color: AppColors.accentMuted,
            ),
          ]),
          SettingsGroup(
            title: 'Temps de visionnage par jour',
            padded: true,
            children: [_DailyChart(stats.daily)],
          ),
          SettingsGroup(
            title: 'Heures de visionnage',
            footer: 'Réparti selon l’heure de début de chaque lecture.',
            padded: true,
            children: [_HourChart(stats.hourOfDay)],
          ),
          SettingsGroup(
            title: 'Titres les plus regardés',
            children: [
              if (stats.topMedia.isEmpty)
                const SettingsEmptyNote('Aucune lecture sur cette période.')
              else
                for (final (i, media) in stats.topMedia.indexed)
                  _RankedMedia(
                    rank: i + 1,
                    media: media,
                    max: stats.topMedia.first.watchedSeconds,
                  ),
            ],
          ),
          if (_userId == null && stats.topUsers.isNotEmpty)
            SettingsGroup(
              title: 'Utilisateurs les plus actifs',
              children: [
                for (final user in stats.topUsers)
                  _BarRow(
                    leading: UserAvatar(user.label, size: 30),
                    label: user.label,
                    detail: '${user.plays} lecture${user.plays > 1 ? 's' : ''}',
                    value: user.watchedSeconds,
                    max: stats.topUsers.first.watchedSeconds,
                  ),
              ],
            ),
          LayoutBuilder(builder: (context, constraints) {
            final apps = SettingsGroup(
              title: 'Applications',
              children: [
                if (stats.clients.isEmpty)
                  const SettingsEmptyNote('—')
                else
                  for (final client in stats.clients)
                    _BarRow(
                      leading:
                          SettingsIcon(deviceIconFor(client.label), size: 30),
                      label: client.label,
                      detail:
                          '${client.plays} lecture${client.plays > 1 ? 's' : ''}',
                      value: client.watchedSeconds,
                      max: stats.clients.first.watchedSeconds,
                    ),
              ],
            );
            final methods = SettingsGroup(
              title: 'Méthodes de lecture',
              footer:
                  'Direct Play et Direct Stream ne coûtent presque rien au serveur ; le transcodage sollicite le processeur.',
              padded: true,
              children: [_MethodsBreakdown(stats.playMethods)],
            );
            if (constraints.maxWidth < 640) {
              return Column(children: [apps, methods]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: apps),
                const SizedBox(width: 16),
                Expanded(child: methods),
              ],
            );
          }),
        ],
      ],
    );
  }
}

class _DailyChart extends StatefulWidget {
  const _DailyChart(this.daily);
  final List<DailyStat> daily;

  @override
  State<_DailyChart> createState() => _DailyChartState();
}

class _DailyChartState extends State<_DailyChart> {
  int? _hovered;

  @override
  Widget build(BuildContext context) {
    final daily = widget.daily;
    if (daily.isEmpty) return const SizedBox(height: 160);
    final maxValue = daily.map((d) => d.watchedSeconds).fold<int>(0, math.max);
    final focus = _hovered == null ? null : daily[_hovered!];
    final total = daily.fold<int>(0, (s, d) => s + d.watchedSeconds);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              focus == null
                  ? formatWatchTime(total)
                  : formatWatchTime(focus.watchedSeconds),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 8),
            Text(
              focus == null
                  ? 'sur la période'
                  : '${formatFrenchDay(focus.date)} · ${focus.plays} lecture${focus.plays > 1 ? 's' : ''}',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12.5),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 150,
          child: LayoutBuilder(builder: (context, constraints) {
            final gap = daily.length > 60
                ? 1.0
                : daily.length > 20
                    ? 3.0
                    : 6.0;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (i, day) in daily.indexed) ...[
                  if (i > 0) SizedBox(width: gap),
                  Expanded(
                    child: MouseRegion(
                      onEnter: (_) => setState(() => _hovered = i),
                      onExit: (_) => setState(() => _hovered = null),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () =>
                            setState(() => _hovered = _hovered == i ? null : i),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(
                              end: maxValue == 0
                                  ? 0
                                  : day.watchedSeconds / maxValue,
                            ),
                            duration: Duration(milliseconds: 350 + i * 6),
                            curve: Curves.easeOutCubic,
                            builder: (_, value, __) => Container(
                              height: math.max(3, 150 * value),
                              decoration: BoxDecoration(
                                color: day.watchedSeconds == 0
                                    ? Colors.white.withValues(alpha: 0.06)
                                    : _hovered == i
                                        ? AppColors.accentMuted
                                        : AppColors.primary.withValues(
                                            alpha:
                                                _hovered == null ? 0.9 : 0.5),
                                borderRadius: BorderRadius.vertical(
                                  top: Radius.circular(
                                      daily.length > 60 ? 1 : 4),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            );
          }),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(formatShortFrenchDate(daily.first.date),
                style:
                    const TextStyle(color: AppColors.textMuted, fontSize: 11)),
            Text(formatShortFrenchDate(daily.last.date),
                style:
                    const TextStyle(color: AppColors.textMuted, fontSize: 11)),
          ],
        ),
      ],
    );
  }
}

class _HourChart extends StatelessWidget {
  const _HourChart(this.hours);
  final List<int> hours;

  @override
  Widget build(BuildContext context) {
    final maxValue = hours.fold<int>(0, math.max);
    return Column(
      children: [
        SizedBox(
          height: 70,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var h = 0; h < 24; h++) ...[
                if (h > 0) const SizedBox(width: 3),
                Expanded(
                  child: Tooltip(
                    message: '${h}h – ${h + 1}h : ${formatWatchTime(hours[h])}',
                    child: Container(
                      height: maxValue == 0
                          ? 3
                          : math.max(3, 70 * hours[h] / maxValue),
                      decoration: BoxDecoration(
                        color: hours[h] == 0
                            ? Colors.white.withValues(alpha: 0.06)
                            : Color.lerp(
                                AppColors.primary.withValues(alpha: 0.35),
                                AppColors.accentMuted,
                                maxValue == 0 ? 0 : hours[h] / maxValue,
                              ),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final label in const ['0h', '6h', '12h', '18h', '23h'])
              Text(label,
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 11)),
          ],
        ),
      ],
    );
  }
}

class _RankedMedia extends StatelessWidget {
  const _RankedMedia(
      {required this.rank, required this.media, required this.max});

  final int rank;
  final StatBucket media;
  final int max;

  @override
  Widget build(BuildContext context) {
    return _BarRow(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '$rank',
              style: TextStyle(
                color: rank <= 3 ? AppColors.textPrimary : AppColors.textMuted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          MediaThumb(
            posterUrl: media.posterUrl,
            width: 34,
            isShow: media.mediaType == 'show',
          ),
        ],
      ),
      label: media.label,
      detail: [
        if (media.secondary.isNotEmpty) media.secondary,
        '${media.plays} lecture${media.plays > 1 ? 's' : ''}',
      ].join(' · '),
      value: media.watchedSeconds,
      max: max,
    );
  }
}

/// Une ligne de classement avec sa barre proportionnelle.
class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.leading,
    required this.label,
    required this.detail,
    required this.value,
    required this.max,
  });

  final Widget leading;
  final String label;
  final String detail;
  final int value;
  final int max;

  @override
  Widget build(BuildContext context) {
    final ratio = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                    ),
                    Text(
                      formatWatchTime(value),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: ratio),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                    builder: (_, v, __) => LinearProgressIndicator(
                      value: v,
                      minHeight: 4,
                      backgroundColor: Colors.white.withValues(alpha: 0.06),
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MethodsBreakdown extends StatelessWidget {
  const _MethodsBreakdown(this.methods);
  final List<StatBucket> methods;

  @override
  Widget build(BuildContext context) {
    final total = methods.fold<int>(0, (s, m) => s + m.plays);
    if (total == 0) {
      return const SettingsEmptyNote('Aucune lecture sur cette période.');
    }
    final parsed = [
      for (final m in methods) (PlayMethod.parse(m.key), m.plays),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 14,
            child: Row(
              children: [
                for (final (method, plays) in parsed)
                  Expanded(
                    flex: math.max(1, (plays * 1000 / total).round()),
                    child: Container(color: playMethodColor(method)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        for (final (method, plays) in parsed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: playMethodColor(method),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(method.label)),
                Text(
                  '${(plays * 100 / total).round()} %',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 70,
                  child: Text(
                    '$plays lecture${plays > 1 ? 's' : ''}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
