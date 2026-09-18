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
    final text = [
      '${entry.headline}${entry.detail.isEmpty ? '' : ' · ${entry.detail}'}',
      '${entry.username} · ${entry.deviceName} · ${entry.client}',
      '${entry.playMethod.label} · ${entry.startedAt.toLocal()}',
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
                'Cette lecture n’a laissé aucun journal. Les lectures faites '
                'avant cette version n’en envoyaient pas, et une app fermée '
                'brutalement n’a pas le temps de le faire.',
                icon: Icons.receipt_long_rounded,
              )
            else
              for (final line in _logs.lines) _LogLine(line: line),
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
