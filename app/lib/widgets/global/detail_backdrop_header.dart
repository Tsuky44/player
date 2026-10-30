import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_type.dart';
import '../../utils/format.dart';
import '../../utils/poster_url.dart';
import 'app_network_image.dart';
import 'detail_cast_section.dart';
import 'detail_hero.dart';

/// L'en-tête d'une fiche de la bibliothèque : [DetailHero], nourri par le
/// catalogue.
///
/// [details] is the live catalog payload (may be null while loading); [fallback]
/// is the local library record used for instant display before it arrives.
class DetailBackdropHeader extends StatelessWidget {
  final Media fallback;
  final MediaDetails? details;
  final List<Widget> metadata;
  final Widget? actions;

  /// Nul quand il n'y a rien derrière la page — celle d'un lien de partage
  /// ouvert dans le navigateur : le bouton retour n'est alors pas dessiné.
  final VoidCallback? onBack;

  /// Badges techniques du fichier (« 4K », « Dolby Atmos »), après la ligne
  /// de métadonnées. Voir `techBadgesFor`.
  final List<String> badges;

  /// True while [details] is still on its way. The backdrop then holds a flat
  /// surface instead of borrowing the poster: stretching a portrait poster to
  /// 1280 px cost a download of its own and was swapped for the real backdrop
  /// a moment later — a second image and a visible flash for nothing.
  final bool loading;

  /// Ce que l'en-tête écrit à la place d'un synopsis absent (« Chargement… »,
  /// « Synopsis indisponible… »).
  final String? emptyOverviewLabel;

  /// Surtitre à la place du type (« SAISON ») : la série, sur la page d'une saison.
  final String? eyebrow;

  const DetailBackdropHeader({
    super.key,
    required this.fallback,
    required this.details,
    required this.metadata,
    required this.onBack,
    this.actions,
    this.badges = const [],
    this.loading = false,
    this.emptyOverviewLabel,
    this.eyebrow,
  });

  /// What the backdrop slot draws: the catalog backdrop, else — once we know
  /// there is none — the poster.
  static String? backdropSource(
    MediaDetails? details,
    Media fallback, {
    bool loading = false,
  }) {
    final backdrop = details?.backdropUrl;
    if (backdrop != null && backdrop.isNotEmpty) return backdrop;
    if (details == null && loading) return null;
    return fallback.posterUrl;
  }

  /// Warms every image the header — and the cast row under it — draws, at the
  /// exact sizes they are drawn at, so a page opened from a hovered or focused
  /// card paints complete on its first frame.
  ///
  /// Sizes mirror [DetailHero] and [CastSection]; a mismatch only costs the
  /// head start, never correctness.
  static Future<void> precacheArtwork({
    required MediaDetails details,
    required Media fallback,
    required String? baseUrl,
    required Size screenSize,
    required double devicePixelRatio,
    required bool compact,
    int castCount = 8,
  }) {
    final dpr = devicePixelRatio;
    return Future.wait([
      AppNetworkImage.precache(
        detailBackdropUrl(
          backdropSource(details, fallback),
          serverBaseUrl: baseUrl,
        ),
        devicePixelRatio: dpr,
        decodeWidth: screenSize.width,
      ),
      AppNetworkImage.precache(
        logoImageUrl(details.logoUrl, serverBaseUrl: baseUrl),
        devicePixelRatio: dpr,
      ),
      if (!compact)
        AppNetworkImage.precache(
          detailPosterUrl(
            details.posterUrl ?? fallback.posterUrl,
            serverBaseUrl: baseUrl,
          ),
          devicePixelRatio: dpr,
          decodeWidth: DetailHero.posterWidth,
        ),
      for (final member in details.cast.take(castCount))
        AppNetworkImage.precache(
          castProfileUrl(member.profileUrl),
          devicePixelRatio: dpr,
          decodeWidth: CastSection.avatarSize,
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final baseUrl = Provider.of<ApiClient>(context, listen: false).baseUrl;
    return DetailHero(
      playKey: fallback.id,
      backdropUrl: detailBackdropUrl(
        backdropSource(details, fallback, loading: loading),
        serverBaseUrl: baseUrl,
      ),
      posterUrl: detailPosterUrl(
        details?.posterUrl ?? fallback.posterUrl,
        serverBaseUrl: baseUrl,
      ),
      logoUrl: logoImageUrl(details?.logoUrl, serverBaseUrl: baseUrl),
      title: details?.title ?? fallback.title,
      tagline: details?.tagline,
      overview: details?.overview ?? fallback.overview,
      emptyOverviewLabel: emptyOverviewLabel,
      // Même surtitre que le bandeau de l'accueil : en capitales espacées,
      // gris — l'accent bleu reste au focus et à la progression.
      eyebrow: Text(
        (eyebrow ?? mediaTypeLabel(fallback.type)).toUpperCase(),
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontWeight: FontWeight.w600,
          fontSize: AppType.caption,
          letterSpacing: 1.6,
        ),
      ),
      metadata: metadata,
      badges: badges,
      actions: actions,
      onBack: onBack,
    );
  }
}
