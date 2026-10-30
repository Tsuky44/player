import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/tr.dart';
import '../../../models/request_release.dart';
import '../../../providers/media_requests_provider.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_icons.dart';
import '../../../theme/app_type.dart';
import '../../../tv/tv_deferred_keyboard.dart';
import '../../../utils/format.dart';
import '../../../utils/responsive.dart';
import '../../../widgets/global/empty_state.dart';

/// La recherche interactive d'une saison ou d'un épisode (ADR-0098) : les
/// releases que les indexeurs offrent, à filtrer, à ranger, et dont on envoie
/// soi-même une au téléchargement, comme dans MediaHub.
///
/// Le compagnon ne dit rien d'une release avant qu'on la choisisse : le nom est
/// tout ce qu'on lit, d'où les étiquettes (définition, source, langue) tirées
/// de lui par [RequestRelease.tags].
class RequestReleaseSheet extends StatefulWidget {
  const RequestReleaseSheet({
    super.key,
    required this.target,
    required this.heading,
  });

  final RequestReleaseTarget target;

  /// Ce qu'on cherche, sous le titre : « Saison 2 », « Saison 2 · Épisode 3 ».
  final String heading;

  static Future<void> show(
    BuildContext context, {
    required RequestReleaseTarget target,
    required String heading,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.85),
      builder: (_) => RequestReleaseSheet(target: target, heading: heading),
    );
  }

  @override
  State<RequestReleaseSheet> createState() => _RequestReleaseSheetState();
}

class _RequestReleaseSheetState extends State<RequestReleaseSheet> {
  final _query = TextEditingController();
  List<RequestRelease>? _releases;
  String? _error;
  bool _loading = true;
  ReleaseSort _sort = ReleaseSort.seeders;

  /// La release en cours d'envoi, et celles déjà parties : un second toucher
  /// ne la renvoie pas.
  String? _sending;
  final _sent = <String>{};

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final releases = await context
          .read<MediaRequestsProvider>()
          .loadReleases(widget.target);
      if (!mounted) return;
      setState(() {
        _releases = releases;
        _loading = false;
        // sorraa range lui-même les releases, la meilleure en tête : on suit
        // son ordre tant qu'on n'en choisit pas un autre.
        _sort =
            _judged(releases) ? ReleaseSort.recommended : ReleaseSort.seeders;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _messageFor(
          error,
          tr('Impossible de charger les releases.'),
        );
        _loading = false;
      });
    }
  }

  /// Un moteur a jugé les releases (sorraa) : l'ordre du compagnon a un sens.
  static bool _judged(List<RequestRelease> releases) =>
      releases.any((release) => release.accepted != null);

  Future<void> _send(RequestRelease release) async {
    if (_sending != null || _sent.contains(release.id)) return;
    setState(() => _sending = release.id);
    final messenger = ScaffoldMessenger.of(context);
    String message;
    try {
      await context
          .read<MediaRequestsProvider>()
          .grabRelease(widget.target, release);
      _sent.add(release.id);
      message = tr('Release envoyée au téléchargement.');
    } catch (error) {
      message = _messageFor(error, tr('Impossible d’envoyer la release.'));
    }
    if (mounted) setState(() => _sending = null);
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Le message du compagnon quand il en donne un (en français, prêt à
  /// afficher), sinon [fallback].
  String _messageFor(Object error, String fallback) {
    if (error is DioException) {
      if (error.response?.statusCode == 501) {
        return tr('Ce serveur ne propose pas la recherche interactive.');
      }
      final data = error.response?.data;
      if (data is Map && data['error'] is String) {
        return data['error'] as String;
      }
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final compact = AppLayout.isCompact(context);
    return Dialog(
      backgroundColor: AppColors.surface,
      insetPadding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 32,
        vertical: compact ? 24 : 40,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppColors.glassBorder),
      ),
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: 760, maxHeight: size.height * 0.86),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            _tools(),
            Flexible(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Recherche interactive'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: AppType.headline,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.heading,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppType.subhead,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: tr('Fermer'),
            icon: const Icon(AppIcons.close, color: AppColors.textSecondary),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _tools() {
    final found = _releases;
    if (found == null || found.isEmpty) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvDeferredKeyboard(
            builder: (context, focusNode, canRequestFocus) => TextField(
              controller: _query,
              focusNode: focusNode,
              canRequestFocus: canRequestFocus,
              textInputAction: TextInputAction.search,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: tr('Filtrer : 1080p, MULTI, remux…'),
                prefixIcon: const Icon(AppIcons.search,
                    size: 20, color: AppColors.textSecondary),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (sort, label) in [
                if (_judged(found))
                  (ReleaseSort.recommended, tr('Recommandées')),
                (ReleaseSort.seeders, tr('Seeders')),
                (ReleaseSort.size, tr('Taille')),
                (ReleaseSort.newest, tr('Récentes')),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _sort == sort,
                  onSelected: (_) => setState(() => _sort = sort),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 56),
        child: LoadingView(),
      );
    }
    if (_error != null) {
      return ErrorStateView(message: _error!, onRetry: _load);
    }
    final all = _releases ?? const <RequestRelease>[];
    if (all.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Center(
          child: Text(
            tr('Aucune release trouvée.'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
        ),
      );
    }
    final shown = RequestRelease.listing(all, query: _query.text, sort: _sort);
    if (shown.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Center(
          child: Text(
            tr('Aucune release ne correspond au filtre.'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      scrollCacheExtent: AppLayout.imageCacheExtent(context),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      itemCount: shown.length,
      separatorBuilder: (context, index) =>
          const Divider(height: 1, color: AppColors.border),
      itemBuilder: (context, index) {
        final release = shown[index];
        return _ReleaseRow(
          release: release,
          sending: _sending == release.id,
          sent: _sent.contains(release.id),
          onSend: release.isDownloadable && _sending == null
              ? () => _send(release)
              : null,
        );
      },
    );
  }
}

class _ReleaseRow extends StatelessWidget {
  const _ReleaseRow({
    required this.release,
    required this.sending,
    required this.sent,
    required this.onSend,
  });

  final RequestRelease release;
  final bool sending;
  final bool sent;
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    final tags = release.tags;
    // Une release que le moteur de sorraa refuserait reste prenable (la choisir
    // à la main est une décision de l'utilisateur), mais s'efface et dit pourquoi.
    return Opacity(
      opacity: release.isRejected && !sent ? 0.6 : 1,
      child: InkWell(
        onTap: sent ? null : onSend,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      release.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: AppType.subhead,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final tag in tags) _Tag(tag),
                        Text(
                          _details(),
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: AppType.footnote,
                          ),
                        ),
                        if (release.seeders != null)
                          Text(
                            '▲ ${release.seeders}',
                            style: TextStyle(
                              color: release.seeders! > 0
                                  ? AppColors.success
                                  : AppColors.error,
                              fontSize: AppType.footnote,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                    if (release.rejections.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        release.rejections.join(' · '),
                        style: const TextStyle(
                          color: AppColors.warning,
                          fontSize: AppType.footnote,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox.square(
                dimension: AppLayout.minTouchTarget(context),
                child: sending
                    ? const Center(
                        child: SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        tooltip: sent
                            ? tr('Release envoyée')
                            : tr('Télécharger cette release'),
                        icon: Icon(
                          sent ? AppIcons.check : AppIcons.download,
                          color: sent ? AppColors.success : Colors.white,
                        ),
                        onPressed: sent ? null : onSend,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// « 2,1 Go · Indexeur · 3 j », sans les morceaux que l'indexeur ne donne pas.
  String _details() => [
        if (release.size > 0) formatBytes(release.size),
        if (release.indexer.isNotEmpty) release.indexer,
        _age(release.ageDays),
      ].join(' · ');

  String _age(double days) {
    if (days < 1) return tr('Aujourd’hui');
    if (days < 60) return tr('{0} j', [days.round()]);
    if (days < 730) return tr('{0} mois', [(days / 30).round()]);
    return tr('{0} ans', [(days / 365).round()]);
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.glassFill,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: AppType.caption,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
