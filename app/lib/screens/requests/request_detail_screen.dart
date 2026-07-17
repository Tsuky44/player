import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/media_request.dart';
import '../../providers/media_requests_provider.dart';
import '../../widgets/global/empty_state.dart';
import 'widgets/request_cast_list.dart';
import 'widgets/request_info_table.dart';
import 'widgets/request_related_slider.dart';

class RequestDetailScreen extends StatefulWidget {
  final RequestMediaItem item;

  const RequestDetailScreen({super.key, required this.item});

  @override
  State<RequestDetailScreen> createState() => _RequestDetailScreenState();
}

class _RequestDetailScreenState extends State<RequestDetailScreen> {
  late Future<RequestMediaDetails> _details;
  final Set<int> _selectedSeasons = {};
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
    if (details.mediaType == RequestMediaType.tv && _selectedSeasons.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sélectionnez au moins une saison.')));
      return;
    }
    setState(() => _submitting = true);
    try {
      await context.read<MediaRequestsProvider>().request(
            details,
            seasons: details.mediaType == RequestMediaType.tv
                ? (_selectedSeasons.toList()..sort())
                : null,
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
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [url]);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [url]);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ouvrez la bande-annonce : $url')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Impossible d’ouvrir la bande-annonce.')));
      }
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
      backgroundColor: const Color(0xFF0F172A),
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
    final canRequest = details.status == RequestMediaStatus.unknown ||
        (details.mediaType == RequestMediaType.tv &&
            details.seasons
                .any((season) => season.status == RequestMediaStatus.unknown));
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
                      _heroHeader(details, canRequest),
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
              if (details.mediaType == RequestMediaType.tv) ...[
                const SizedBox(height: 40),
                _seasonsSection(details),
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
          if (details.backdropUrl != null)
            CachedNetworkImage(
              imageUrl: details.backdropUrl!,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
            )
          else
            const ColoredBox(color: Color(0xFF0F172A)),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  const Color(0xFF0F172A).withValues(alpha: 0.92),
                  const Color(0xFF0F172A).withValues(alpha: 0.55),
                  const Color(0xFF0F172A).withValues(alpha: 0.2),
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
                  Color(0xFF0F172A),
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

  Widget _heroHeader(RequestMediaDetails details, bool canRequest) {
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
          if (details.logoUrl != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 150),
              child: CachedNetworkImage(
                imageUrl: details.logoUrl!,
                fit: BoxFit.contain,
                alignment: Alignment.centerLeft,
                errorWidget: (_, __, ___) => _titleFallback(details),
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
            children: [
              _primaryButton(
                label: canRequest ? 'Demander' : 'Déjà demandé',
                icon: Icons.download_rounded,
                filled: true,
                enabled: canRequest && !_submitting,
                loading: _submitting,
                onPressed: () => _request(details),
              ),
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
    final bg =
        filled ? const Color(0xFF3B82F6) : Colors.white.withValues(alpha: 0.06);
    final border = filled
        ? Colors.transparent
        : const Color(0xFFEF4444).withValues(alpha: 0.55);
    final fg = enabled ? Colors.white : Colors.white.withValues(alpha: 0.4);

    return Material(
      color: enabled ? bg : bg.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
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

  Widget _seasonsSection(RequestMediaDetails details) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Saisons à demander',
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
        const SizedBox(height: 12),
        ...details.seasons.map((season) {
          final selectable = season.status == RequestMediaStatus.unknown;
          return CheckboxListTile(
            value: _selectedSeasons.contains(season.number),
            onChanged: !selectable
                ? null
                : (selected) => setState(() {
                      if (selected == true) {
                        _selectedSeasons.add(season.number);
                      } else {
                        _selectedSeasons.remove(season.number);
                      }
                    }),
            title: Text(season.name,
                style: const TextStyle(color: Colors.white)),
            subtitle: Text(
                selectable
                    ? '${season.episodeCount} épisodes'
                    : 'Déjà disponible ou demandée',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.45))),
            activeColor: const Color(0xFF3B82F6),
            contentPadding: EdgeInsets.zero,
          );
        }),
      ],
    );
  }
}
