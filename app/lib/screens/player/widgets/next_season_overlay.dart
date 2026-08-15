import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../models/models.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/global/app_network_image.dart';

/// End-of-season page, shown when the season that follows is not on the server.
///
/// Deliberately unlike [NextEpisodeOverlay]: no countdown and no automatic
/// action. Sending a request is a commitment, so it always waits for a tap.
///
/// It occupies the space left free by the shrunk video rather than floating
/// over it — the credits stay watchable to the left while this reads as a full
/// panel, the way Crunchyroll and Netflix end a season.
///
/// The same page also runs one episode early, on the outro of the penultimate
/// episode ([onPlayNext] set): asking then lets the download and the import run
/// while the finale plays. In that mode it also carries the way forward, since
/// it replaces the auto-advance pill it would otherwise sit on top of.
class NextSeasonOverlay extends StatelessWidget {
  final NextSeason season;
  final bool submitting;
  final VoidCallback onRequest;
  final VoidCallback onDismiss;

  /// Set only when an episode still follows this one — the early offer.
  final VoidCallback? onPlayNext;

  /// Width reserved on the left for the shrunk video.
  final double videoInset;

  const NextSeasonOverlay({
    super.key,
    required this.season,
    required this.submitting,
    required this.onRequest,
    required this.onDismiss,
    this.onPlayNext,
    this.videoInset = 0,
  });

  bool get _lookahead => onPlayNext != null;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      bottom: 0,
      left: videoInset,
      right: 0,
      child: Material(
        color: Colors.transparent,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (context, t, child) {
            return Opacity(
              opacity: t.clamp(0, 1),
              child: Transform.translate(
                offset: Offset(28 * (1 - t), 0),
                child: child,
              ),
            );
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              _Backdrop(posterUrl: season.posterUrl),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(40, 28, 44, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Eyebrow(
                        season: season,
                        lookahead: _lookahead,
                        onDismiss: onDismiss,
                      ),
                      const Spacer(),
                      Flexible(
                        flex: 8,
                        child: SingleChildScrollView(
                          child: _Body(season: season, lookahead: _lookahead),
                        ),
                      ),
                      const Spacer(),
                      _Actions(
                        season: season,
                        submitting: submitting,
                        onRequest: onRequest,
                        onDismiss: onDismiss,
                        onPlayNext: onPlayNext,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Blurred poster wash behind the panel, so the page has a colour of its own
/// instead of sitting on flat black.
class _Backdrop extends StatelessWidget {
  final String? posterUrl;

  const _Backdrop({required this.posterUrl});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (posterUrl != null)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
            child: Opacity(
              opacity: 0.32,
              child: AppNetworkImage(
                // 60px of blur — a small decode is indistinguishable here, and
                // this overlay appears mid-playback where nothing may stutter.
                url: posterUrl,
                fit: BoxFit.cover,
                decodeWidth: 320,
                placeholder: const SizedBox.shrink(),
                errorWidget: const SizedBox.shrink(),
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                AppColors.background,
                AppColors.background.withValues(alpha: 0.92),
                AppColors.background.withValues(alpha: 0.78),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Eyebrow extends StatelessWidget {
  final NextSeason season;
  final bool lookahead;
  final VoidCallback onDismiss;

  const _Eyebrow({
    required this.season,
    required this.lookahead,
    required this.onDismiss,
  });

  String get _label {
    if (season.isRequested) return 'DEMANDE ENVOYÉE';
    if (lookahead) return 'PLUS QU’UN ÉPISODE';
    return 'SAISON TERMINÉE';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
            color: AppColors.accent,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 2.2,
            ),
          ),
        ),
        _CloseButton(onTap: onDismiss),
      ],
    );
  }
}

class _CloseButton extends StatefulWidget {
  final VoidCallback onTap;

  const _CloseButton({required this.onTap});

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hovered ? AppColors.surfaceHover : Colors.transparent,
            border: Border.all(
              color: _hovered ? AppColors.border : Colors.transparent,
            ),
          ),
          child: Icon(
            Icons.close_rounded,
            size: 18,
            color: _hovered ? AppColors.textPrimary : AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final NextSeason season;
  final bool lookahead;

  const _Body({required this.season, required this.lookahead});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (season.posterUrl != null) ...[
          _Poster(url: season.posterUrl!),
          const SizedBox(width: 24),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (season.showTitle.isNotEmpty) ...[
                Text(
                  season.showTitle.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.6,
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Text(
                season.name.isNotEmpty ? season.name : 'Saison ${season.number}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 14),
              _MetaRow(season: season, lookahead: lookahead),
              const SizedBox(height: 16),
              Text(
                _description(season, lookahead),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                  height: 1.55,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _description(NextSeason season, bool lookahead) {
    if (season.isRequested) {
      return lookahead
          ? 'Demande envoyée. Le téléchargement se lance pendant que tu '
              'termines l’épisode en cours.'
          : 'Cette saison a déjà été demandée. Elle apparaîtra dans ta '
              'bibliothèque dès qu’elle sera disponible.';
    }
    if (lookahead) {
      return 'Il ne reste plus qu’un épisode disponible, et la saison '
          '${season.number} n’est pas sur le serveur. La demander maintenant '
          'lui laisse le temps de se télécharger pendant que tu le regardes.';
    }
    if (season.overview?.isNotEmpty == true) return season.overview!;
    return 'Cette saison n’est pas encore sur le serveur.';
  }
}

class _Poster extends StatelessWidget {
  final String url;

  const _Poster({required this.url});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.55),
              blurRadius: 32,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: AppNetworkImage(
          url: url,
          width: 132,
          height: 198,
          fit: BoxFit.cover,
          errorWidget: const SizedBox.shrink(),
        ),
      ),
    );
  }
}

/// Episode count, air year and request state as compact pills.
class _MetaRow extends StatelessWidget {
  final NextSeason season;
  final bool lookahead;

  const _MetaRow({required this.season, required this.lookahead});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (lookahead)
          const _Pill(
            label: '1 épisode restant',
            icon: Icons.playlist_play_rounded,
          ),
        if (season.episodeCount > 0)
          _Pill(label: '${season.episodeCount} épisodes'),
        if (season.isRequested)
          const _Pill(
            label: 'En attente',
            icon: Icons.hourglass_top_rounded,
            accent: true,
          )
        else if (!season.canRequest)
          const _Pill(
            label: 'Indisponible',
            icon: Icons.cloud_off_outlined,
          )
        else
          const _Pill(
            label: 'Absente du serveur',
            icon: Icons.cloud_off_outlined,
          ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool accent;

  const _Pill({required this.label, this.icon, this.accent = false});

  @override
  Widget build(BuildContext context) {
    final color = accent ? AppColors.accentMuted : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: AppColors.surfaceElevated.withValues(alpha: 0.7),
        border: Border.all(
          color: accent ? AppColors.primary : AppColors.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  final NextSeason season;
  final bool submitting;
  final VoidCallback onRequest;
  final VoidCallback onDismiss;
  final VoidCallback? onPlayNext;

  const _Actions({
    required this.season,
    required this.submitting,
    required this.onRequest,
    required this.onDismiss,
    this.onPlayNext,
  });

  @override
  Widget build(BuildContext context) {
    if (!season.canRequest) {
      // Already requested, or MediaHub could not be consulted: informative only.
      // The way forward still belongs here when an episode follows, since this
      // page stands in for the auto-advance pill.
      return Row(
        children: [
          if (onPlayNext != null) ...[
            _NextEpisodeButton(onTap: onPlayNext!, primary: true),
            const SizedBox(width: 8),
          ],
          TextButton(
            onPressed: onDismiss,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            ),
            child: const Text('Fermer'),
          ),
        ],
      );
    }

    return Row(
      children: [
        ElevatedButton.icon(
          onPressed: submitting ? null : onRequest,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          icon: submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download_rounded, size: 19),
          label: Text('Demander la saison ${season.number}'),
        ),
        const SizedBox(width: 8),
        if (onPlayNext != null) ...[
          _NextEpisodeButton(
            onTap: onPlayNext!,
            primary: false,
            enabled: !submitting,
          ),
          const SizedBox(width: 8),
        ],
        TextButton(
          onPressed: submitting ? null : onDismiss,
          style: TextButton.styleFrom(
            foregroundColor: AppColors.textSecondary,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          ),
          child: const Text('Non merci'),
        ),
      ],
    );
  }
}

/// Way out of the page towards the episode that still follows, so requesting
/// the season and watching on stay two independent choices.
class _NextEpisodeButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool primary;
  final bool enabled;

  const _NextEpisodeButton({
    required this.onTap,
    required this.primary,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    const label = Text('Épisode suivant');
    const icon = Icon(Icons.skip_next_rounded, size: 19);
    final padding = EdgeInsets.symmetric(
      horizontal: primary ? 28 : 22,
      vertical: primary ? 20 : 18,
    );
    const textStyle = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );

    if (primary) {
      return ElevatedButton.icon(
        onPressed: enabled ? onTap : null,
        style: ElevatedButton.styleFrom(
          padding: padding,
          shape: shape,
          textStyle: textStyle,
        ),
        icon: icon,
        label: label,
      );
    }

    return OutlinedButton.icon(
      onPressed: enabled ? onTap : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        side: const BorderSide(color: AppColors.border),
        padding: padding,
        shape: shape,
        textStyle: textStyle,
      ),
      icon: icon,
      label: label,
    );
  }
}
