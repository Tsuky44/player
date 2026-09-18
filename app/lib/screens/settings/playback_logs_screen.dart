import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/server_activity.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import 'widgets/settings_ui.dart';

/// Le journal qu'une lecture passée a laissé derrière elle.
///
/// L'historique disait déjà quoi, qui, où et combien de temps. Ce qu'il ne
/// disait pas est ce qui s'est passé — et c'est la seule question qui compte
/// devant une lecture de quatre secondes. Les lignes viennent du client qui
/// lisait, envoyées à la fin de la séance ; voir `playback_logs.go`.
class PlaybackLogsScreen extends StatefulWidget {
  const PlaybackLogsScreen(this.entry, {super.key});

  final PlaybackHistoryEntry entry;

  @override
  State<PlaybackLogsScreen> createState() => _PlaybackLogsScreenState();
}

class _PlaybackLogsScreenState extends State<PlaybackLogsScreen> {
  PlaybackLogs _logs = PlaybackLogs.empty;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final logs =
          await context.read<ApiClient>().getPlaybackLogs(widget.entry.id);
      if (!mounted) return;
      setState(() => _logs = logs);
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _error = settingsErrorText(e, 'Impossible de charger ce journal.'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// L'entête dit de quelle lecture ce journal vient, comme celui de l'app dit
  /// de quel appareil : collé ailleurs, il doit se suffire.
  Future<void> _copy() async {
    final entry = widget.entry;
    final stats = _logs.stats;
    final text = [
      '${entry.headline}${entry.detail.isEmpty ? '' : ' · ${entry.detail}'}',
      '${entry.username} · ${entry.deviceName} · ${entry.client}',
      '${entry.playMethod.label} · ${entry.startedAt.toLocal()}',
      // Les mesures partent avec les lignes : collées dans un message, elles
      // répondent avant qu'on ait eu à les redemander.
      if (stats != null && !stats.isEmpty) ...[
        '',
        for (final metric in describePlaybackStats(stats))
          '${metric.label} : ${metric.value}',
      ],
      '',
      for (final line in _logs.lines) line.format(),
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showSettingsSnack(context, 'Journal copié.');
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Journal de lecture'),
        actions: [
          IconButton(
            tooltip: 'Copier',
            onPressed: _logs.isEmpty ? null : _copy,
            icon: const Icon(Icons.copy_rounded),
          ),
          IconButton(
            tooltip: 'Actualiser',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
          children: [
            _Header(entry: entry, hasError: _logs.hasError),
            const SizedBox(height: 16),
            if (_loading)
              const SettingsLoading()
            else if (_error != null)
              SettingsBanner(_error!, tone: BannerTone.error)
            else if (_logs.isEmpty)
              const SettingsEmptyNote(
                'Cette lecture n’a laissé ni journal ni mesures. Les lectures '
                'faites avant cette version n’en envoyaient pas, et une app '
                'fermée brutalement n’a pas le temps de le faire.',
                icon: Icons.receipt_long_rounded,
              )
            else ...[
              if (_logs.stats != null && !_logs.stats!.isEmpty) ...[
                _StatsCard(stats: _logs.stats!),
                const SizedBox(height: 20),
              ],
              if (_logs.hasLines)
                for (final line in _logs.lines) _LogLine(line: line)
              else
                const SettingsEmptyNote(
                  'Mesures sans journal : cette lecture s’est déroulée sans '
                  'rien avoir à signaler.',
                  icon: Icons.check_circle_outline_rounded,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// De quelle lecture il s'agit, avant les lignes elles-mêmes.
class _Header extends StatelessWidget {
  const _Header({required this.entry, required this.hasError});

  final PlaybackHistoryEntry entry;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          entry.detail.isEmpty ? entry.headline : '${entry.headline} · ${entry.detail}',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SettingsPill(entry.username, icon: Icons.person_rounded),
            if (entry.deviceName.isNotEmpty)
              SettingsPill(entry.deviceName, icon: Icons.devices_rounded),
            SettingsPill(
              entry.playMethod.label,
              color: playMethodColor(entry.playMethod),
            ),
            SettingsPill(relativeTime(entry.startedAt),
                icon: Icons.schedule_rounded),
            if (hasError)
              const SettingsPill('Erreur',
                  color: AppColors.error, icon: Icons.error_outline_rounded),
          ],
        ),
      ],
    );
  }
}

/// Une ligne, sélectionnable — voir la page Journal des réglages, dont c'est
/// le pendant côté serveur.
class _LogLine extends StatelessWidget {
  const _LogLine({required this.line});

  final PlaybackLogLine line;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 3,
            constraints: const BoxConstraints(minHeight: 18),
            margin: const EdgeInsets.only(top: 2, right: 10),
            decoration: BoxDecoration(
              color: line.isError ? AppColors.error : AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: SelectableText(
              line.format(),
              style: TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Menlo', 'Consolas', 'Roboto Mono'],
                fontSize: 12,
                height: 1.4,
                color: line.isError ? AppColors.error : AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Une mesure prête à lire : son intitulé, sa valeur, et ce qu'elle vaut.
class PlaybackMetric {
  const PlaybackMetric(this.label, this.value, {this.tone = MetricTone.plain});

  final String label;
  final String value;
  final MetricTone tone;
}

/// Ce qu'une mesure dit de la lecture, quand elle dit quelque chose.
///
/// La couleur n'est pas décorative : elle épargne d'avoir à savoir à partir de
/// quel taux de pertes une lecture saccade. Elle ne sert que là où un seuil a
/// un sens — un débit moyen n'est ni bon ni mauvais dans l'absolu.
enum MetricTone { plain, good, warn, bad }

/// Met les mesures en mots, dans l'ordre où on se pose les questions.
///
/// Partagé entre la carte et le bouton « Copier », pour que le texte collé dans
/// une conversation dise exactement ce que l'écran disait.
List<PlaybackMetric> describePlaybackStats(PlaybackSessionStats stats) {
  String seconds(double value) =>
      value < 10 ? '${value.toStringAsFixed(1)} s' : '${value.round()} s';

  String bitrate(double bps) {
    if (bps >= 1000000) return '${(bps / 1000000).toStringAsFixed(1)} Mb/s';
    if (bps >= 1000) return '${(bps / 1000).round()} kb/s';
    return '${bps.round()} b/s';
  }

  final metrics = <PlaybackMetric>[];

  final fps = stats.averageFps;
  final container = stats.containerFps;
  if (fps != null) {
    // Comparée à la cadence du fichier plutôt que rendue seule : « 19 images
    // par seconde » ne dit rien tant qu'on ignore que le film en demandait 24.
    final expected = container ?? 0;
    final tone = expected <= 0
        ? MetricTone.plain
        : fps >= expected * 0.95
            ? MetricTone.good
            : fps >= expected * 0.85
                ? MetricTone.warn
                : MetricTone.bad;
    metrics.add(PlaybackMetric(
      'Images par seconde',
      expected > 0
          ? '${fps.toStringAsFixed(1)} / ${container!.toStringAsFixed(3)}'
          : fps.toStringAsFixed(1),
      tone: tone,
    ));
  } else if (container != null) {
    metrics
        .add(PlaybackMetric('Cadence du fichier', container.toStringAsFixed(3)));
  }

  final ratio = stats.dropRatio;
  if (ratio != null) {
    metrics.add(PlaybackMetric(
      'Images perdues',
      '${stats.droppedFrames} (${(ratio * 100).toStringAsFixed(ratio < 0.01 ? 2 : 1)} %)',
      tone: ratio < 0.001
          ? MetricTone.good
          : ratio < 0.01
              ? MetricTone.warn
              : MetricTone.bad,
    ));
  } else if (stats.droppedFrames != null) {
    metrics.add(PlaybackMetric('Images perdues', '${stats.droppedFrames}'));
  }

  final average = stats.averageBitrateBps;
  if (average != null) {
    metrics.add(PlaybackMetric('Débit moyen', bitrate(average)));
  }
  final video = stats.videoBitrateBps;
  if (video != null) {
    metrics.add(PlaybackMetric('Débit vidéo', bitrate(video)));
  }
  final audio = stats.audioBitrateBps;
  if (audio != null) {
    metrics.add(PlaybackMetric('Débit audio', bitrate(audio)));
  }

  final decoder = stats.decoder;
  if (decoder != null && decoder.isNotEmpty) {
    metrics.add(PlaybackMetric(
      'Décodage',
      stats.looksSoftwareDecoded ? '$decoder (logiciel)' : decoder,
      tone: stats.looksSoftwareDecoded ? MetricTone.warn : MetricTone.good,
    ));
  }
  final videoCodec = stats.videoCodec;
  if (videoCodec != null && videoCodec.isNotEmpty) {
    metrics.add(PlaybackMetric('Codec vidéo', videoCodec));
  }
  final audioCodec = stats.audioCodec;
  if (audioCodec != null && audioCodec.isNotEmpty) {
    metrics.add(PlaybackMetric('Codec audio', audioCodec));
  }

  final startup = stats.startupMillis;
  if (startup != null) {
    metrics.add(PlaybackMetric(
      'Démarrage',
      startup >= 1000
          ? '${(startup / 1000).toStringAsFixed(1)} s'
          : '$startup ms',
      tone: startup < 2000
          ? MetricTone.good
          : startup < 5000
              ? MetricTone.warn
              : MetricTone.bad,
    ));
  }

  if (stats.bufferingEvents > 0) {
    metrics.add(PlaybackMetric(
      'Mises en tampon',
      '${stats.bufferingEvents} · ${seconds(stats.bufferingSeconds)}',
      tone: stats.bufferingEvents <= 2 ? MetricTone.warn : MetricTone.bad,
    ));
  } else if (stats.sampleCount > 0) {
    metrics.add(
        const PlaybackMetric('Mises en tampon', 'aucune', tone: MetricTone.good));
  }

  metrics.add(PlaybackMetric('Mesuré sur', seconds(stats.sampledSeconds)));
  return metrics;
}

/// Les mesures, en grille.
///
/// Avant la première ligne du journal : elles répondent d'un coup d'œil à ce
/// que les lignes n'expliquent qu'en se laissant lire en entier.
class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.stats});

  final PlaybackSessionStats stats;

  static Color _color(MetricTone tone) => switch (tone) {
        MetricTone.good => AppColors.success,
        MetricTone.warn => AppColors.warning,
        MetricTone.bad => AppColors.error,
        MetricTone.plain => AppColors.textPrimary,
      };

  @override
  Widget build(BuildContext context) {
    final metrics = describePlaybackStats(stats);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Mesures de la lecture',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          // Une grille qui se replie : deux colonnes sur un téléphone, quatre
          // sur un écran large, sans point de rupture écrit à la main.
          LayoutBuilder(builder: (context, constraints) {
            final columns = (constraints.maxWidth / 180).floor().clamp(2, 4);
            final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 14,
              children: [
                for (final metric in metrics)
                  SizedBox(
                    width: width,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          metric.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textMuted),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          metric.value,
                          maxLines: 2,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _color(metric.tone),
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          }),
        ],
      ),
    );
  }
}
