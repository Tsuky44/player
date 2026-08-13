import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';

/// Bottom sheet that lets the user re-identify a movie/show by picking the
/// correct entry from a live TMDB search. The original filename is shown at the
/// top so the user can tell what the file actually is.
///
/// Returns the chosen [TmdbCandidate] via [Navigator.pop], or null if cancelled.
class MetadataFixSheet extends StatefulWidget {
  final ApiClient api;
  final String initialQuery;
  final String? fileName;
  final String? fileHintLabel;
  final String? localFolder;
  final String? localEpisodeFile;
  final MediaType type;

  const MetadataFixSheet({
    super.key,
    required this.api,
    required this.initialQuery,
    required this.type,
    this.fileName,
    this.fileHintLabel,
    this.localFolder,
    this.localEpisodeFile,
  });

  static Future<TmdbCandidate?> show(
    BuildContext context, {
    required ApiClient api,
    required String initialQuery,
    required MediaType type,
    String? fileName,
    String? fileHintLabel,
    String? localFolder,
    String? localEpisodeFile,
  }) {
    return showModalBottomSheet<TmdbCandidate>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MetadataFixSheet(
        api: api,
        initialQuery: initialQuery,
        type: type,
        fileName: fileName,
        fileHintLabel: fileHintLabel,
        localFolder: localFolder,
        localEpisodeFile: localEpisodeFile,
      ),
    );
  }

  @override
  State<MetadataFixSheet> createState() => _MetadataFixSheetState();
}

class _MetadataFixSheetState extends State<MetadataFixSheet> {
  late final TextEditingController _controller;
  List<TmdbCandidate> _results = const [];
  bool _loading = false;
  bool _searched = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    _search();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await widget.api.searchTmdb(query, type: widget.type);
      if (!mounted) return;
      setState(() {
        _results = results;
        _searched = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Recherche TMDB impossible');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: DraggableScrollableSheet(
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Corriger la fiche',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (widget.type == MediaType.show) ...[
                        const SizedBox(height: 10),
                        _LocalShowContextCard(
                          folder: widget.localFolder,
                          episodeFile: widget.localEpisodeFile,
                        ),
                      ] else if (widget.fileName != null &&
                          widget.fileName!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _FileNameChip(
                          fileName: widget.fileName!,
                          label: widget.fileHintLabel ?? 'Fichier local',
                        ),
                      ],
                      const SizedBox(height: 14),
                      TextField(
                        controller: _controller,
                        autofocus: false,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _search(),
                        decoration: InputDecoration(
                          hintText: 'Rechercher un titre…',
                          filled: true,
                          fillColor: AppColors.surface,
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.arrow_forward),
                            onPressed: _search,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: _buildBody(scrollController)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(ScrollController scrollController) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          _searched ? 'Aucun résultat' : 'Lance une recherche',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      );
    }
    return ListView.separated(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final c = _results[index];
        return _CandidateTile(
          candidate: c,
          onTap: () => Navigator.of(context).pop(c),
        );
      },
    );
  }
}

class _LocalShowContextCard extends StatelessWidget {
  final String? folder;
  final String? episodeFile;

  const _LocalShowContextCard({
    this.folder,
    this.episodeFile,
  });

  @override
  Widget build(BuildContext context) {
    final hasFolder = folder != null && folder!.trim().isNotEmpty;
    final hasEpisode = episodeFile != null && episodeFile!.trim().isNotEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.textSecondary.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Sur le serveur',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 8),
          _LocalRow(
            icon: Icons.folder_outlined,
            label: 'Dossier série',
            value: hasFolder ? folder! : '— aucun chemin indexé —',
            muted: !hasFolder,
          ),
          if (hasEpisode) ...[
            const SizedBox(height: 8),
            _LocalRow(
              icon: Icons.movie_outlined,
              label: 'Fichier épisode',
              value: episodeFile!,
            ),
          ],
        ],
      ),
    );
  }
}

class _LocalRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool muted;

  const _LocalRow({
    required this.icon,
    required this.label,
    required this.value,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppColors.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: AppColors.textSecondary.withValues(alpha: 0.9),
                  fontSize: 11,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  color: muted
                      ? AppColors.textMuted
                      : AppColors.textPrimary,
                  fontSize: 13,
                  fontFamily: 'monospace',
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FileNameChip extends StatelessWidget {
  final String fileName;
  final String label;

  const _FileNameChip({
    required this.fileName,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.textSecondary.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: AppColors.textSecondary.withValues(alpha: 0.85),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.insert_drive_file_outlined,
                  size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  fileName,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontFamily: 'monospace',
                    height: 1.3,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  final TmdbCandidate candidate;
  final VoidCallback onTap;

  const _CandidateTile({required this.candidate, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 60,
              height: 90,
              child: candidate.posterUrl != null
                  ? Image.network(
                      candidate.posterUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const _PosterFallback(),
                    )
                  : const _PosterFallback(),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  candidate.year != null && candidate.year!.isNotEmpty
                      ? '${candidate.title} (${candidate.year})'
                      : candidate.title,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                if (candidate.overview != null &&
                    candidate.overview!.isNotEmpty)
                  Text(
                    candidate.overview!,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                      height: 1.3,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      child: const Icon(Icons.movie_outlined,
          color: AppColors.textSecondary, size: 24),
    );
  }
}
