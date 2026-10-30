import 'dart:async';

import '../../utils/external_url.dart';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/media_request.dart';
import '../../models/models.dart' show CastMember, MediaType;
import '../../navigation/catalog_navigation.dart';
import '../../navigation/play_link.dart';
import '../../services/api_client.dart';
import '../../providers/media_requests_provider.dart';
import '../../theme/app_colors.dart';
import '../../utils/poster_url.dart';
import '../../widgets/global/detail_cast_section.dart';
import '../../widgets/global/detail_hero.dart';
import '../../widgets/global/detail_metadata.dart';
import '../../widgets/global/detail_summary_section.dart';
import '../../widgets/global/empty_state.dart';
import '../../widgets/global/poster_rail.dart';
import '../../utils/long_date.dart';
import '../../utils/responsive.dart';
import 'widgets/request_detail_hero.dart';
import 'widgets/request_info_table.dart';
import 'widgets/request_media_card.dart';
import 'widgets/request_progress_panel.dart';
import 'widgets/request_season_list.dart';
import 'widgets/request_status_badge.dart';
import '../../theme/app_icons.dart';
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
  bool _launching = false;

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

  /// Un film se demande d'ici. Une saison se demande en la dépliant, dans la
  /// liste des saisons ([RequestSeasonList]).
  Future<void> _request(RequestMediaDetails details) async {
    setState(() => _submitting = true);
    try {
      await context.read<MediaRequestsProvider>().request(details);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Demande envoyée à MediaHub.'))));
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        // MediaHub dit pourquoi il refuse (droit, quota, déjà demandé) :
        // son message passe tel quel.
        final data = error is DioException ? error.response?.data : null;
        final message = data is Map && data['error'] is String
            ? data['error'] as String
            : tr('Impossible d’envoyer la demande.');
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
        setState(() => _submitting = false);
      }
    }
  }

  /// « Lire » : le titre est déjà dans la bibliothèque (en entier ou en
  /// partie), la fiche de lecture s'ouvre et lance la lecture, comme le lien
  /// « Lire sur Onyx » de MediaHub (ADR-0091).
  Future<void> _play(RequestMediaDetails details) async {
    final api = context.read<ApiClient>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final type = details.mediaType == RequestMediaType.tv
        ? MediaType.show
        : MediaType.movie;
    setState(() => _launching = true);
    final route = await PlayLink.routeForTmdb(api, type, details.id);
    if (!mounted) return;
    setState(() => _launching = false);
    if (route == null) {
      PlayLink.notFound(messenger);
      return;
    }
    unawaited(navigator.push(route));
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

  /// Le chargement garde le fond que l'envol vient de poser : la carte le
  /// connaît déjà, et la fiche n'attend pas le réseau pour avoir son image.
  Widget _loading() {
    if (widget.item.backdropUrl == null) return const LoadingView();
    return Stack(
      children: [
        DetailBackdrop(url: detailBackdropUrl(widget.item.backdropUrl)),
        const LoadingView(),
      ],
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
            return _loading();
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

  Widget _content(RequestMediaDetails details) {
    final isTv = details.mediaType == RequestMediaType.tv;
    final waiting = details.waitingMessage;
    final tracked = details.status != RequestMediaStatus.available &&
        details.status != RequestMediaStatus.unknown;

    return CustomScrollView(
      scrollCacheExtent: AppLayout.imageCacheExtent(context),
      slivers: [
        SliverToBoxAdapter(
          child: DetailHero(
            playKey: details.id,
            backdropUrl: detailBackdropUrl(details.backdropUrl),
            posterUrl: detailPosterUrl(details.posterUrl),
            logoUrl: logoImageUrl(details.logoUrl),
            title: details.title,
            tagline: details.tagline,
            overview: details.overview,
            emptyOverviewLabel: tr('Aucun synopsis disponible.'),
            eyebrow: _eyebrow(details),
            metadata: buildMetadataChips(
              type: isTv ? MediaType.show : MediaType.movie,
              releaseDate: details.releaseDate,
              runtimeMinutes: details.runtime ?? 0,
              rating: details.rating,
              seasons: details.numberOfSeasons ?? 0,
              genres: details.genres,
            ),
            actions: _actions(details),
            onBack: () => Navigator.of(context).pop(),
          ),
        ),
        // Sous l'en-tête et non dedans : sa hauteur est fixe, et le suivi d'une
        // demande a la taille qu'il veut.
        if ((waiting != null && details.status != RequestMediaStatus.available) ||
            tracked)
          SliverToBoxAdapter(
            child: Padding(
              padding: AppLayout.pageInsets(context, top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (waiting != null &&
                      details.status != RequestMediaStatus.available)
                    RequestImportNotice(message: waiting),
                  // Le suivi vient de MediaHub : un titre disponible n'a plus
                  // rien à montrer, les autres sont interrogés tant que l'écran
                  // est ouvert.
                  if (tracked)
                    RequestProgressPanel(
                        tmdbId: details.id, mediaType: details.mediaType),
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: DetailSummarySection(
            credits: [
              if (details.director != null && details.director!.isNotEmpty)
                (label: tr('Réalisateur'), value: details.director!),
              for (final writer in details.writers)
                (label: tr('Scénario'), value: writer),
              for (final editor in details.editors)
                (label: tr('Montage'), value: editor),
            ],
            keywords: details.keywords,
            infoTable: RequestInfoTable(details: details),
          ),
        ),
        if (isTv && details.seasons.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: AppLayout.pageInsets(context, top: 48),
              child: RequestSeasonList(
                tmdbId: details.id,
                showItem: widget.item,
                seasons: details.seasons,
              ),
            ),
          ),
        if (details.cast.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 40),
              child: CastSection(
                cast: [
                  for (final member in details.cast.take(25))
                    CastMember(
                      tmdbId: member.tmdbId,
                      name: member.name,
                      character: member.character,
                      profileUrl: member.profileUrl,
                    ),
                ],
                onTapMember: (member) =>
                    openPerson(context, member.tmdbId, name: member.name),
              ),
            ),
          ),
        for (final (title, items) in [
          (tr('Recommandations'), details.recommendations),
          (tr('Titres similaires'), details.similar),
        ])
          if (items.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 32),
                child: PosterRail(
                  title: title,
                  itemCount: items.length,
                  itemBuilder: (context, index) =>
                      RequestMediaCard(item: items[index]),
                ),
              ),
            ),
        const SliverToBoxAdapter(child: SizedBox(height: 56)),
      ],
    );
  }

  /// OnyxHub cache le surtitre en téléphone : la pastille de statut des
  /// boutons dit déjà la même chose, juste en dessous.
  Widget? _eyebrow(RequestMediaDetails details) {
    if (AppLayout.isCompact(context) ||
        details.status == RequestMediaStatus.unknown) {
      return null;
    }
    return RequestAvailabilityBadge(
      status: details.status,
      awaitingRelease: details.isAwaitingRelease(),
    );
  }

  /// La rangée d'actions : le statut ou « Demander », la bande-annonce et les
  /// listes.
  Widget _actions(RequestMediaDetails details) {
    final compact = AppLayout.isCompact(context);
    return Wrap(
      spacing: compact ? 8 : 14,
      runSpacing: compact ? 8 : 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ..._requestActions(details),
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
              style:
                  heroRoundButtonStyle(context, DetailActions.secondaryStyle)),
          child: AddToListButton(title: ListableTitle.catalog(widget.item)),
        ),
      ],
    );
  }

  /// Les pastilles de statut d'OnyxHub (`RequestStatusButton`).
  List<Widget> _requestActions(RequestMediaDetails details) {
    final status = details.status;
    final isTv = details.mediaType == RequestMediaType.tv;

    // Disponible, même en partie : le bouton lance le média. Le statut se
    // lit dans le surtitre au-dessus du titre (RequestAvailabilityBadge).
    Widget playButton() => HeroPill(
          label: tr('Lire'),
          icon: AppIcons.play,
          style: HeroPillStyle.glass,
          loading: _launching,
          onPressed: _launching ? null : () => _play(details),
        );

    if (status == RequestMediaStatus.partial ||
        status == RequestMediaStatus.available) {
      return [playButton()];
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
      ];
    }

    // Une série se demande saison par saison, en dépliant celle qu'on veut.
    if (isTv || !status.canRequest) return const [];

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
}
