import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../l10n/tr.dart';
import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../services/client_log.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';
import '../../tv/tv_focus.dart';
import '../../tv/tv_mode.dart';
import 'app_network_image.dart';
import 'empty_state.dart';

/// Ce que la feuille rend : une affiche choisie, ou le retour à celle de TMDB.
sealed class _PosterChoice {
  const _PosterChoice();
}

class _ChosenPoster extends _PosterChoice {
  final RemotePoster poster;
  const _ChosenPoster(this.poster);
}

class _DefaultPoster extends _PosterChoice {
  const _DefaultPoster();
}

/// Le choix de l'affiche d'un film ou d'une série parmi celles que TMDB et
/// Fanart.tv proposent, à la façon d'Emby (ADR-0068).
///
/// Le serveur réserve l'écriture à `manage_library` : l'écran qui ouvre cette
/// feuille n'en montre l'entrée qu'aux comptes qui ont ce droit.
class PosterPickerSheet extends StatefulWidget {
  final ApiClient api;
  final Media media;

  const PosterPickerSheet({super.key, required this.api, required this.media});

  /// Ouvre la feuille, enregistre le choix et rend la fiche à jour ; null
  /// quand rien n'a changé. Les messages de réussite et d'échec sont dits ici,
  /// pour que la fiche d'un film et celle d'une série disent les mêmes.
  static Future<Media?> pickAndApply(
    BuildContext context, {
    required ApiClient api,
    required Media media,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final choice = await showModalBottomSheet<_PosterChoice>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PosterPickerSheet(api: api, media: media),
    );
    if (choice == null) return null;
    try {
      final updated = switch (choice) {
        _ChosenPoster(:final poster) =>
          await api.setMediaPoster(media.id, poster.url),
        _DefaultPoster() => await api.resetMediaPoster(media.id),
      };
      messenger.showSnackBar(SnackBar(
        content: Text(choice is _DefaultPoster
            ? tr('Affiche par défaut rétablie')
            : tr('Affiche mise à jour')),
      ));
      return updated;
    } catch (e) {
      ClientLog.error('Affiche de ${media.id} : $e');
      messenger.showSnackBar(SnackBar(
        content: Text(tr('Impossible d’enregistrer l’affiche. Réessayez.')),
      ));
      return null;
    }
  }

  @override
  State<PosterPickerSheet> createState() => _PosterPickerSheetState();
}

/// Les sources qu'on peut isoler dans la grille.
enum _SourceFilter { all, tmdb, fanart }

class _PosterPickerSheetState extends State<PosterPickerSheet> {
  RemotePosters? _posters;
  bool _loading = true;

  /// Le serveur ne sait pas proposer d'affiches (version antérieure).
  bool _unsupported = false;
  String? _error;
  _SourceFilter _filter = _SourceFilter.all;

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
      final posters = await widget.api.getRemotePosters(widget.media.id);
      if (!mounted) return;
      setState(() {
        _posters = posters;
        _unsupported = posters == null;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.response?.statusCode == 403
          ? tr('Votre compte ne peut pas modifier la médiathèque.')
          : tr('Les sites d’affiches ne répondent pas. Réessayez.'));
    } catch (e) {
      ClientLog.error('Affiches proposées pour ${widget.media.id} : $e');
      if (!mounted) return;
      setState(() =>
          _error = tr('Les sites d’affiches ne répondent pas. Réessayez.'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<RemotePoster> get _visible {
    final images = _posters?.images ?? const <RemotePoster>[];
    return switch (_filter) {
      _SourceFilter.all => images,
      _SourceFilter.tmdb => images.where((p) => p.source == 'tmdb').toList(),
      _SourceFilter.fanart =>
        images.where((p) => p.source == 'fanart').toList(),
    };
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textSecondary.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              _Header(
                title: widget.media.title,
                canReset: _posters?.locked ?? false,
                onReset: () =>
                    Navigator.of(context).pop(const _DefaultPoster()),
              ),
              if (_hasBothSources) _buildFilters(),
              Expanded(child: _buildBody(scrollController)),
            ],
          ),
        );
      },
    );
  }

  bool get _hasBothSources {
    final images = _posters?.images ?? const <RemotePoster>[];
    return images.any((p) => p.source == 'tmdb') &&
        images.any((p) => p.source == 'fanart');
  }

  Widget _buildFilters() {
    final labels = {
      _SourceFilter.all: tr('Toutes'),
      _SourceFilter.tmdb: 'TMDB',
      _SourceFilter.fanart: 'Fanart.tv',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Wrap(
        spacing: 8,
        children: [
          for (final entry in labels.entries)
            ChoiceChip(
              label: Text(entry.value),
              selected: _filter == entry.key,
              onSelected: (_) => setState(() => _filter = entry.key),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(ScrollController scrollController) {
    if (_loading) return const LoadingView();
    if (_error != null) {
      return ErrorStateView(message: _error!, onRetry: _load);
    }
    if (_unsupported) {
      return EmptyStateView(
        icon: AppIcons.poster,
        title: tr('Serveur à mettre à jour'),
        message: tr('Ce serveur ne sait pas encore proposer d’affiches. '
            'Mettez-le à jour pour en choisir une.'),
      );
    }
    final posters = _posters!;
    final visible = _visible;
    if (visible.isEmpty) {
      return EmptyStateView(
        icon: AppIcons.poster,
        title: tr('Aucune affiche trouvée'),
        message: tr('Si la fiche n’est pas la bonne œuvre, corrigez-la '
            'd’abord : les affiches suivent son identification.'),
      );
    }
    return CustomScrollView(
      controller: scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 150,
              mainAxisSpacing: 16,
              crossAxisSpacing: 12,
              // L'affiche en 2:3 et une ligne de légende dessous.
              childAspectRatio: 0.56,
            ),
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final poster = visible[index];
              return _PosterTile(
                poster: poster,
                current: poster.url == posters.current,
                autofocus: TvMode.isTv && index == 0,
                onTap: () => Navigator.of(context).pop(_ChosenPoster(poster)),
              );
            },
          ),
        ),
        if (!posters.fanartEnabled)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Text(
                tr('Ajoutez une clé Fanart.tv dans Réglages › Métadonnées '
                    'pour voir aussi ses affiches.'),
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: AppType.footnote,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final bool canReset;
  final VoidCallback onReset;

  const _Header({
    required this.title,
    required this.canReset,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Changer l’affiche'),
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: AppType.title3,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppType.subhead,
                  ),
                ),
              ],
            ),
          ),
          if (canReset)
            TextButton.icon(
              onPressed: onReset,
              icon: const Icon(AppIcons.reset, size: 18),
              label: Text(tr('Affiche par défaut')),
            ),
        ],
      ),
    );
  }
}

class _PosterTile extends StatelessWidget {
  final RemotePoster poster;
  final bool current;
  final bool autofocus;
  final VoidCallback onTap;

  const _PosterTile({
    required this.poster,
    required this.current,
    required this.autofocus,
    required this.onTap,
  });

  String get _caption {
    final language = poster.language;
    return language == null
        ? tr('{0} · sans texte', [poster.sourceLabel])
        : '${poster.sourceLabel} · ${language.toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(10));
    return Semantics(
      button: true,
      selected: current,
      label: current
          ? tr('Affiche actuelle, {0}', [_caption])
          : tr('Choisir cette affiche, {0}', [_caption]),
      excludeSemantics: true,
      child: TvFocusable(
        onSelect: onTap,
        autofocus: autofocus,
        focusScale: 1.0,
        scrollAlignment: 0.3,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: radius,
                      child: AppNetworkImage(
                        url: poster.thumbUrl,
                        fit: BoxFit.cover,
                        errorWidget: const ColoredBox(
                          color: AppColors.surface,
                          child: Icon(AppIcons.imageBroken,
                              color: AppColors.textMuted),
                        ),
                      ),
                    ),
                    if (current)
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: radius,
                          border:
                              Border.all(color: AppColors.accent, width: 3),
                        ),
                        child: const Align(
                          alignment: Alignment.topRight,
                          child: Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(AppIcons.watchedFilled,
                                color: AppColors.accent, size: 22),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: current ? AppColors.accent : AppColors.textSecondary,
                  fontSize: AppType.caption,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
