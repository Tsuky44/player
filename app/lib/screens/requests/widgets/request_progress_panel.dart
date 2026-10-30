import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../l10n/tr.dart';
import '../../../models/media_request.dart';
import '../../../models/request_progress.dart';
import '../../../providers/media_requests_provider.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_type.dart';

/// Les widgets de téléchargement et d'import de MediaHub, sous les boutons
/// d'une demande. Tout vient de MediaHub (qui lit Radarr, Sonarr ou sorraa) :
/// l'écran interroge le serveur d'Onyx toutes les [interval] tant qu'il est
/// ouvert, et ne dessine rien quand rien n'est en cours.
class RequestProgressPanel extends StatefulWidget {
  const RequestProgressPanel({
    super.key,
    required this.tmdbId,
    required this.mediaType,
    this.interval = const Duration(seconds: 5),
  });

  final int tmdbId;
  final RequestMediaType mediaType;
  final Duration interval;

  @override
  State<RequestProgressPanel> createState() => _RequestProgressPanelState();
}

class _RequestProgressPanelState extends State<RequestProgressPanel> {
  RequestProgress? _progress;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(widget.interval, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final progress = await context
        .read<MediaRequestsProvider>()
        .loadProgress(widget.tmdbId, widget.mediaType);
    if (mounted) setState(() => _progress = progress);
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    if (progress == null) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 580),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (progress.download != null)
            _ProgressCard(
              label: tr('Téléchargement'),
              title: progress.download!.releaseTitle,
              percent: progress.download!.progress,
              details: [
                if (progress.download!.speed != null)
                  '${progress.download!.speed}',
                if (progress.download!.sizeLeft != null)
                  tr('reste {0}', [progress.download!.sizeLeft!]),
                if (progress.download!.timeLeft != null)
                  tr('{0} restant', [progress.download!.timeLeft!]),
              ],
            ),
          for (final item in progress.imports)
            _ProgressCard(
              label: tr('Importation'),
              title: item.releaseName,
              percent: item.progress,
              failed: item.failed,
              details: [
                tr('{0} sur {1} fichiers copiés',
                    ['${item.filesDone}', '${item.files}']),
                tr('{0} sur {1}', [item.sizeDone, item.size]),
              ],
              note: item.failed
                  ? (item.message ?? tr('Import échoué'))
                  : item.current == null
                      ? null
                      : tr('Copie de {0}', [item.current!]),
            ),
        ],
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.label,
    required this.percent,
    required this.details,
    this.title,
    this.note,
    this.failed = false,
  });

  final String label;
  final String? title;
  final double percent;
  final List<String> details;
  final String? note;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final color = failed ? AppColors.error : AppColors.warning;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  color: color.withValues(alpha: 0.85),
                  fontWeight: FontWeight.w700,
                  fontSize: AppType.micro,
                  letterSpacing: 0.8,
                ),
              ),
              const Spacer(),
              Text(
                '${percent.round()} %',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: AppType.footnote,
                ),
              ),
            ],
          ),
          if (title != null) ...[
            const SizedBox(height: 6),
            Text(
              title!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: AppType.micro,
              ),
            ),
          ],
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: percent / 100,
              minHeight: 4,
              color: color,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
            ),
          ),
          if (details.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              details.join(' • '),
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: AppType.footnote,
              ),
            ),
          ],
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(
              note!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: failed ? AppColors.error : AppColors.textMuted,
                fontSize: AppType.footnote,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
