import '../../utils/external_url.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/media_request.dart';
import '../../providers/media_requests_provider.dart';
import '../../theme/app_colors.dart';
import '../../utils/poster_url.dart';
import '../../widgets/global/app_network_image.dart';
import '../../widgets/global/empty_state.dart';
import 'widgets/request_cast_list.dart';
import 'widgets/request_info_table.dart';
import 'widgets/request_related_slider.dart';
import 'widgets/request_season_list.dart';
import 'widgets/request_status_badge.dart';
import 'widgets/season_selector_dialog.dart';

class RequestDetailScreen extends StatefulWidget {
  final RequestMediaItem item;

  const RequestDetailScreen({super.key, required this.item});

  @override
  State<RequestDetailScreen> createState() => _RequestDetailScreenState();
}

class _RequestDetailScreenState extends State<RequestDetailScreen> {
  late Future<RequestMediaDetails> _details;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _details = context.read<MediaRequestsProvider>().loadDetails(widget.item);
  }

  void _retry() {
    setState(() {
      _details = context.read<MediaRequestsProvider>().loadDetails(widget.item);
    });
  }

  Future<void> _request(RequestMediaDetails details) async {
    List<int>? seasons;
    if (details.mediaType == RequestMediaType.tv) {
      seasons = await SeasonSelectorDialog.show(
        context,
        title: details.title,
        seasons: details.seasons,
      );
      if (seasons == null || seasons.isEmpty) return;
    }

    if (!mounted) return;
    setState(() => _submitting = true);
    try {
      await context.read<MediaRequestsProvider>().request(
            details,
            seasons: seasons,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Demande envoyée à MediaHub.')));
      Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Impossible d’envoyer la demande.')));
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _openTrailer(String key) async {
    final url = 'https://www.youtube.com/watch?v=$key';
    if (await openExternalUrl(url)) return;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ouvrez la bande-annonce : $url')));
    }
  }

  void _openRelated(RequestMediaItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RequestDetailScreen(item: item)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: FutureBuilder<RequestMediaDetails>(
        future: _details,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingView();
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return ErrorStateView(
                message: 'Impossible de charger ce média.', onRetry: _retry);
          }
          return _content(snapshot.data!);
        },
      ),
    );
  }

  Widget _content(RequestMediaDetails details) {
    final hasUnrequestedSeasons =
        details.seasons.any((season) => season.status.canRequest);
    final canRequest = details.mediaType == RequestMediaType.tv
        ? hasUnrequestedSeasons
        : details.status.canRequest;
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 1100;
    final horizontal = width >= 900 ? 48.0 : 20.0;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Stack(
            children: [
              _heroBackdrop(details),
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(horizontal, 8, horizontal, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _backButton(),
                      SizedBox(height: width >= 800 ? 120 : 72),
                      _heroHeader(details, canRequest, hasUnrequestedSeasons),
                      const SizedBox(height: 36),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 56),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 8, child: _mainColumn(details)),
                    const SizedBox(width: 36),
                    SizedBox(
                        width: 340, child: RequestInfoTable(details: details)),
                  ],
                )
              else ...[
                _mainColumn(details),
                const SizedBox(height: 28),
                RequestInfoTable(details: details),
              ],
              if (details.mediaType == RequestMediaType.tv &&
                  details.seasons.isNotEmpty) ...[
                const SizedBox(height: 40),
                RequestSeasonList(
                  tmdbId: details.id,
                  showItem: widget.item,
                  seasons: details.seasons,
                ),
              ],
              if (details.cast.isNotEmpty) ...[
                const SizedBox(height: 40),
                const Text('Casting',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
                const SizedBox(height: 14),
                RequestCastList(cast: details.cast),
              ],
              if (details.recommendations.isNotEmpty) ...[
                const SizedBox(height: 44),
                RequestRelatedSlider(
                  title: 'Recommandations',
                  items: details.recommendations,
                  onTap: _openRelated,
                ),
              ],
              if (details.similar.isNotEmpty) ...[
                const SizedBox(height: 36),
                RequestRelatedSlider(
                  title: 'Titres similaires',
                  items: details.similar,
                  onTap: _openRelated,
                ),
              ],
            ]),
          ),
        ),
      ],
    );
  }

  Widget _heroBackdrop(RequestMediaDetails details) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.62,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AppNetworkImage(
            url: backdropImageUrl(details.backdropUrl),
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            decodeWidth: MediaQuery.sizeOf(context).width,
            fadeInDuration: const Duration(milliseconds: 220),
            placeholder: const ColoredBox(color: AppColors.background),
            errorWidget: const ColoredBox(color: AppColors.background),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  AppColors.background.withValues(alpha: 0.92),
                  AppColors.background.withValues(alpha: 0.55),
                  AppColors.background.withValues(alpha: 0.2),
                ],
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  AppColors.background,
                ],
                stops: [0.35, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _backButton() {
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => Navigator.of(context).pop(),
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: Icon(Icons.arrow_back_rounded, color: Colors.white, size: 22),
        ),
      ),
    );
  }

  Widget _heroHeader(
    RequestMediaDetails details,
    bool canRequest,
    bool hasUnrequestedSeasons,
  ) {
    final runtime = details.formattedRuntime;
    final hasLogo = details.logoUrl != null;
    final metaParts = <Widget>[
      if (hasLogo && details.year != null)
        Text(details.year!,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 15)),
      if (runtime.isNotEmpty)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule_rounded,
                size: 16, color: Colors.white.withValues(alpha: 0.45)),
            const SizedBox(width: 5),
            Text(runtime,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7), fontSize: 14)),
          ],
        ),
      ...details.genres.map(
        (genre) => Text('• $genre',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75), fontSize: 14)),
      ),
    ];

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 920),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (details.status != RequestMediaStatus.unknown) ...[
            RequestAvailabilityBadge(status: details.status),
            const SizedBox(height: 14),
          ],
          if (details.logoUrl != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 150),
              child: AppNetworkImage(
                // Same normalised size the library detail header asks for, so
                // a title already browsed there draws from cache.
                url: logoImageUrl(details.logoUrl),
                fit: BoxFit.contain,
                alignment: Alignment.centerLeft,
                decodeAtSourceSize: true,
                placeholder: _titleFallback(details),
                errorWidget: _titleFallback(details),
              ),
            )
          else
            _titleFallback(details),
          const SizedBox(height: 16),
          Wrap(
            spacing: 14,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: metaParts,
          ),
          const SizedBox(height: 22),
          Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
          const SizedBox(height: 18),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ..._requestActions(details, canRequest, hasUnrequestedSeasons),
              if (details.trailerKey != null && details.trailerKey!.isNotEmpty)
                _primaryButton(
                  label: 'Bande-annonce',
                  icon: Icons.play_circle_outline_rounded,
                  filled: false,
                  enabled: true,
                  onPressed: () => _openTrailer(details.trailerKey!),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Action buttons mirroring MediaHub RequestStatusButton.
  List<Widget> _requestActions(
    RequestMediaDetails details,
    bool canRequest,
    bool hasUnrequestedSeasons,
  ) {
    final status = details.status;
    final isTv = details.mediaType == RequestMediaType.tv;

    if (status == RequestMediaStatus.partial) {
      return [
        _statusActionButton(
          label: 'Partiellement disponible',
          icon: Icons.check_rounded,
          foreground: AppColors.warning,
          background: AppColors.warning,
        ),
        if (canRequest && isTv && hasUnrequestedSeasons)
          _primaryButton(
            label: 'Compléter',
            icon: Icons.add_rounded,
            filled: true,
            enabled: !_submitting,
            loading: _submitting,
            onPressed: () => _request(details),
          ),
      ];
    }

    if (status == RequestMediaStatus.available) {
      return [
        _statusActionButton(
          label: 'Disponible',
          icon: Icons.check_rounded,
          foreground: AppColors.success,
          background: AppColors.success,
        ),
        if (canRequest && hasUnrequestedSeasons && isTv)
          _primaryButton(
            label: 'Demander plus',
            icon: Icons.add_rounded,
            filled: true,
            enabled: !_submitting,
            loading: _submitting,
            onPressed: () => _request(details),
          ),
      ];
    }

    if (status == RequestMediaStatus.pending ||
        status == RequestMediaStatus.processing) {
      return [
        _statusActionButton(
          label: 'En cours de traitement...',
          icon: Icons.hourglass_top_rounded,
          foreground: AppColors.accentMuted,
          background: AppColors.primary,
        ),
        if (canRequest && hasUnrequestedSeasons && isTv)
          _primaryButton(
            label: 'Demander plus',
            icon: Icons.add_rounded,
            filled: true,
            enabled: !_submitting,
            loading: _submitting,
            onPressed: () => _request(details),
          ),
      ];
    }

    if (!canRequest) return const [];

    return [
      _primaryButton(
        label: 'Demander',
        icon: Icons.download_rounded,
        filled: true,
        enabled: !_submitting,
        loading: _submitting,
        onPressed: () => _request(details),
      ),
    ];
  }

  Widget _statusActionButton({
    required String label,
    required IconData icon,
    required Color foreground,
    required Color background,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: background.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: background.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: foreground),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _titleFallback(RequestMediaDetails details) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: details.title.toUpperCase(),
            style: const TextStyle(
              fontSize: 42,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              height: 1.05,
              letterSpacing: -0.5,
            ),
          ),
          if (details.year != null)
            TextSpan(
              text: ' (${details.year})',
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w300,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
        ],
      ),
    );
  }

  Widget _primaryButton({
    required String label,
    required IconData icon,
    required bool filled,
    required bool enabled,
    required VoidCallback onPressed,
    bool loading = false,
  }) {
    final bg = filled
        ? AppColors.textPrimary
        : Colors.white.withValues(alpha: 0.06);
    final border = filled
        ? Colors.transparent
        : Colors.white.withValues(alpha: 0.12);
    final baseFg = filled ? AppColors.background : AppColors.textPrimary;
    final fg = enabled ? baseFg : baseFg.withValues(alpha: 0.4);

    return Material(
      color: enabled ? bg : bg.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                )
              else
                Icon(icon, size: 20, color: fg),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mainColumn(RequestMediaDetails details) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _crewGrid(details),
        if (details.keywords.isNotEmpty) ...[
          const SizedBox(height: 24),
          Divider(color: Colors.white.withValues(alpha: 0.06)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: details.keywords
                .map(
                  (keyword) => Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.sell_outlined,
                            size: 12,
                            color: Colors.white.withValues(alpha: 0.4)),
                        const SizedBox(width: 6),
                        Text(
                          keyword,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.55),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
        ],
        const SizedBox(height: 28),
        Divider(color: Colors.white.withValues(alpha: 0.06)),
        const SizedBox(height: 18),
        const Text('Résumé',
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
        const SizedBox(height: 12),
        Text(
          details.overview.isEmpty
              ? 'Aucun synopsis disponible.'
              : details.overview,
          style: TextStyle(
            height: 1.6,
            fontSize: 15,
            color: Colors.white.withValues(alpha: 0.72),
          ),
        ),
      ],
    );
  }

  Widget _crewGrid(RequestMediaDetails details) {
    final entries = <MapEntry<String, String>>[
      if (details.director != null && details.director!.isNotEmpty)
        MapEntry('Réalisateur', details.director!),
      ...details.writers.map((w) => MapEntry('Scénario', w)),
      ...details.editors.map((e) => MapEntry('Montage', e)),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 520 ? 3 : 2;
        return Wrap(
          spacing: 24,
          runSpacing: 22,
          children: entries.map((entry) {
            return SizedBox(
              width: (constraints.maxWidth - (columns - 1) * 24) / columns,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.key,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14)),
                  const SizedBox(height: 4),
                  Text(entry.value,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 14)),
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }

}
