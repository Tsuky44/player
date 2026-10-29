import '../../utils/external_url.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/media_request.dart';
import '../../providers/media_requests_provider.dart';
import '../../theme/app_colors.dart';
import '../../utils/poster_url.dart';
import '../../widgets/global/app_network_image.dart';
import '../../widgets/global/empty_state.dart';
import '../../utils/long_date.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/staggered_entrance.dart';
import 'widgets/request_detail_hero.dart';
import 'widgets/request_cast_list.dart';
import 'widgets/request_info_table.dart';
import 'widgets/request_related_slider.dart';
import 'widgets/request_season_list.dart';
import 'widgets/request_status_badge.dart';
import 'widgets/season_selector_dialog.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';
import '../../l10n/tr.dart';
import '../../widgets/global/detail_actions.dart';
import '../../models/watch_list.dart';
import '../../widgets/global/add_to_list_button.dart';

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
          SnackBar(content: Text(tr('Demande envoyée à OnyxHub.'))));
      Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('Impossible d’envoyer la demande.'))));
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _openTrailer(String key) async {
    final url =
        'https://www.youtube.com/watch?v=${Uri.encodeQueryComponent(key)}';
    if (await openExternalUrl(url)) return;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Ouvrez la bande-annonce : {0}', [url]))));
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
                message: tr('Impossible de charger ce média.'),
                onRetry: _retry);
          }
          return _content(snapshot.data!);
        },
      ),
    );
  }

  /// La marge des côtés : la page court d'un bord à l'autre, comme le fond.
  ///
  /// OnyxHub plafonne son contenu à 1600 px et le centre : sur un écran de
  /// 2000 px, l'en-tête et le corps se retrouvaient chacun centré à sa façon,
  /// avec 200 px de vide de chaque côté. Ici une seule marge, proportionnelle
  /// à l'écran (3 %, entre 48 et 72 px), aligne le logo, le texte et les
  /// rangées sur le même bord. Ce sont les blocs de texte qui gardent une
  /// largeur lisible, pas la page.
  static double _gutter(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (AppLayout.isCompact(context)) return 16;
    if (width < 900) return 24;
    return (width * 0.03).clamp(48.0, 72.0);
  }

  /// La colonne d'informations à droite : un quart de l'écran, assez pour
  /// les studios sur une ligne, jamais au point d'écraser le texte.
  static double _sidebarWidth(double width) =>
      (width * 0.24).clamp(340.0, 460.0);

  Widget _content(RequestMediaDetails details) {
    final hasUnrequestedSeasons =
        details.seasons.any((season) => season.status.canRequest);
    final canRequest = details.mediaType == RequestMediaType.tv
        ? hasUnrequestedSeasons
        : details.status.canRequest;
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 1100;
    final compact = AppLayout.isCompact(context);
    final horizontal = _gutter(context);

    return CustomScrollView(
      scrollCacheExtent: AppLayout.imageCacheExtent(context),
      slivers: [
        SliverToBoxAdapter(
          child: Stack(
            children: [
              RequestDetailBackdrop(backdropUrl: details.backdropUrl),
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(horizontal, 8, horizontal, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _backButton(),
                      // Le titre se pose dans le bas de l'image, comme sur
                      // OnyxHub.
                      SizedBox(
                          height:
                              compact ? size.height * 0.22 : size.height * 0.3),
                      _heroHeader(details, canRequest, hasUnrequestedSeasons),
                      const SizedBox(height: 48),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 56),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _mainColumn(details)),
                      const SizedBox(width: 56),
                      SizedBox(
                        width: _sidebarWidth(size.width),
                        child: RequestInfoTable(details: details),
                      ),
                    ],
                  )
                else ...[
                  _mainColumn(details),
                  const SizedBox(height: 28),
                  RequestInfoTable(details: details),
                ],
                if (details.mediaType == RequestMediaType.tv &&
                    details.seasons.isNotEmpty) ...[
                  const SizedBox(height: 56),
                  RequestSeasonList(
                    tmdbId: details.id,
                    showItem: widget.item,
                    seasons: details.seasons,
                  ),
                ],
                if (details.cast.isNotEmpty) ...[
                  const SizedBox(height: 48),
                  Text(tr('Casting'),
                      style: const TextStyle(
                          fontSize: AppType.title1,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 16),
                  RequestCastList(cast: details.cast),
                ],
                if (details.recommendations.isNotEmpty) ...[
                  const SizedBox(height: 56),
                  RequestRelatedSlider(
                    title: tr('Recommandations'),
                    items: details.recommendations,
                    onTap: _openRelated,
                  ),
                ],
                if (details.similar.isNotEmpty) ...[
                  const SizedBox(height: 40),
                  RequestRelatedSlider(
                    title: tr('Titres similaires'),
                    items: details.similar,
                    onTap: _openRelated,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
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
          child: Icon(AppIcons.back, color: Colors.white, size: 22),
        ),
      ),
    );
  }

  Widget _heroHeader(
    RequestMediaDetails details,
    bool canRequest,
    bool hasUnrequestedSeasons,
  ) {
    final compact = AppLayout.isCompact(context);
    final runtime = details.formattedRuntime;
    final hasLogo = details.logoUrl != null;
    final muted = Colors.white.withValues(alpha: 0.6);
    final metaParts = <Widget>[
      if (hasLogo && details.year != null)
        Text(details.year!,
            style: const TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w800,
                fontSize: AppType.headline)),
      if (runtime.isNotEmpty)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.schedule, size: 16, color: muted),
            const SizedBox(width: 6),
            Text(runtime,
                style: TextStyle(
                    color: muted,
                    fontSize: AppType.body,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ...details.genres.map(
        (genre) => Text('• $genre',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: AppType.body,
                fontWeight: FontWeight.w500)),
      ),
    ];

    // OnyxHub cache le surtitre en téléphone : la pastille de statut des
    // boutons dit déjà la même chose, juste en dessous.
    final showBadge = !compact && details.status != RequestMediaStatus.unknown;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1150),
      child: StaggeredEntranceScope(
        playKey: details.id,
        maxAnimated: 4,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StaggeredEntrance(
              index: 0,
              child: showBadge
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: RequestAvailabilityBadge(
                        status: details.status,
                        awaitingRelease: details.isAwaitingRelease(),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            StaggeredEntrance(
              index: 1,
              child: details.logoUrl != null
                  ? ConstrainedBox(
                      constraints: BoxConstraints(
                          maxWidth: compact ? 280 : 420,
                          maxHeight: compact ? 140 : 180),
                      child: AppNetworkImage(
                        // Same normalised size the library detail header asks
                        // for, so a title already browsed there draws from
                        // cache.
                        url: logoImageUrl(details.logoUrl),
                        fit: BoxFit.contain,
                        alignment: Alignment.centerLeft,
                        decodeAtSourceSize: true,
                        placeholder: _titleFallback(details),
                        errorWidget: _titleFallback(details),
                      ),
                    )
                  : _titleFallback(details),
            ),
            StaggeredEntrance(
              index: 2,
              child: Padding(
                padding: const EdgeInsets.only(top: 18),
                child: Wrap(
                  spacing: 14,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: metaParts,
                ),
              ),
            ),
            StaggeredEntrance(
              index: 3,
              child: Padding(
                padding: const EdgeInsets.only(top: 24),
                child: _actions(details, canRequest, hasUnrequestedSeasons),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// La rangée d'actions d'OnyxHub (`MediaPrimaryActions`) : un filet, puis
  /// le statut ou « Demander », la bande-annonce et les listes ; le cadre
  /// d'import dessous quand le serveur en a un.
  Widget _actions(
    RequestMediaDetails details,
    bool canRequest,
    bool hasUnrequestedSeasons,
  ) {
    final compact = AppLayout.isCompact(context);
    final waiting = details.waitingMessage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
        SizedBox(height: compact ? 14 : 20),
        Wrap(
          spacing: compact ? 8 : 14,
          runSpacing: compact ? 8 : 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ..._requestActions(details, canRequest, hasUnrequestedSeasons),
            if (details.trailerKey != null && details.trailerKey!.isNotEmpty)
              HeroPill(
                label: tr('Bande-annonce'),
                icon: AppIcons.playCircle,
                style: HeroPillStyle.trailer,
                iconOnlyWhenCompact: true,
                onPressed: () => _openTrailer(details.trailerKey!),
              ),
            // Un titre que le serveur n'a pas peut déjà aller dans « À
            // regarder plus tard » (ADR-0070).
            IconButtonTheme(
              data: IconButtonThemeData(
                  style: heroRoundButtonStyle(
                      context, DetailActions.secondaryStyle)),
              child: AddToListButton(title: ListableTitle.catalog(widget.item)),
            ),
          ],
        ),
        if (waiting != null &&
            details.status != RequestMediaStatus.available) ...[
          SizedBox(height: compact ? 14 : 20),
          RequestImportNotice(message: waiting),
        ],
      ],
    );
  }

  /// Les pastilles de statut d'OnyxHub (`RequestStatusButton`).
  List<Widget> _requestActions(
    RequestMediaDetails details,
    bool canRequest,
    bool hasUnrequestedSeasons,
  ) {
    final status = details.status;
    final isTv = details.mediaType == RequestMediaType.tv;
    final more = canRequest && isTv && hasUnrequestedSeasons;

    Widget moreButton(String label) => HeroPill(
          label: label,
          icon: AppIcons.add,
          style: HeroPillStyle.glass,
          loading: _submitting,
          onPressed: _submitting ? null : () => _request(details),
        );

    if (status == RequestMediaStatus.partial) {
      return [
        HeroPill(
          label: tr('Partiellement disponible'),
          icon: AppIcons.pending,
          iconColor: AppColors.warning,
          style: HeroPillStyle.status,
        ),
        if (more) moreButton(tr('Compléter')),
      ];
    }

    if (status == RequestMediaStatus.available) {
      return [
        HeroPill(
          label: tr('Disponible'),
          icon: AppIcons.check,
          iconColor: AppColors.success,
          style: HeroPillStyle.status,
          beam: true,
        ),
        if (more) moreButton(tr('Demander plus')),
      ];
    }

    if (status == RequestMediaStatus.pending ||
        status == RequestMediaStatus.processing) {
      final awaiting = details.isAwaitingRelease();
      final release = DateTime.tryParse(details.releaseDate ?? '');
      return [
        awaiting
            ? HeroPill(
                label: release == null
                    ? tr('En attente de sortie')
                    : tr('Sortie le {0}', [formatLongDate(release)]),
                icon: AppIcons.calendar,
                style: HeroPillStyle.status,
              )
            : HeroPill(
                label: tr('En cours de traitement'),
                style: HeroPillStyle.status,
                track: true,
              ),
        if (more) moreButton(tr('Demander plus')),
      ];
    }

    if (!canRequest) return const [];

    return [
      HeroPill(
        label: _submitting ? tr('Envoi de la demande') : tr('Demander'),
        icon: AppIcons.download,
        style: HeroPillStyle.glass,
        loading: _submitting,
        onPressed: _submitting ? null : () => _request(details),
      ),
    ];
  }

  Widget _titleFallback(RequestMediaDetails details) {
    final compact = AppLayout.isCompact(context);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: details.title,
            style: TextStyle(
              fontSize: compact ? AppType.largeTitle : AppType.hero + 16,
              fontWeight: FontWeight.w900,
              color: AppColors.textPrimary,
              height: 1.05,
              letterSpacing: -0.5,
            ),
          ),
          if (details.year != null)
            TextSpan(
              text: ' (${details.year})',
              style: TextStyle(
                fontSize: compact ? AppType.title1 : AppType.hero,
                fontWeight: FontWeight.w200,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
        ],
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
                        Icon(AppIcons.tag,
                            size: 12,
                            color: Colors.white.withValues(alpha: 0.4)),
                        const SizedBox(width: 6),
                        Text(
                          keyword,
                          style: TextStyle(
                            fontSize: AppType.footnote,
                            color: AppColors.textMuted,
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
        Text(tr('Résumé'),
            style: TextStyle(
                fontSize: AppType.title2,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
        const SizedBox(height: 12),
        // La page va d'un bord à l'autre ; le paragraphe garde une ligne
        // lisible (~110 caractères), comme le `max-w-4xl` d'OnyxHub.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Text(
            details.overview.isEmpty
                ? tr('Aucun synopsis disponible.')
                : details.overview,
            style: TextStyle(
              height: 1.6,
              fontSize: AppType.callout,
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
        ),
      ],
    );
  }

  Widget _crewGrid(RequestMediaDetails details) {
    final entries = <MapEntry<String, String>>[
      if (details.director != null && details.director!.isNotEmpty)
        MapEntry(tr('Réalisateur'), details.director!),
      ...details.writers.map((w) => MapEntry(tr('Scénario'), w)),
      ...details.editors.map((e) => MapEntry(tr('Montage'), e)),
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
                          fontSize: AppType.body)),
                  const SizedBox(height: 4),
                  Text(entry.value,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: AppType.body)),
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }
}
