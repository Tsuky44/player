import 'package:flutter/material.dart';
import '../../../models/media_request.dart';
import '../../../theme/app_colors.dart';
import 'request_status_badge.dart';

/// Modal to pick which seasons to request for a TV show.
/// Returns the selected season numbers, or null if cancelled.
/// Already available / partial / pending seasons are shown but not selectable
/// (MediaHub logic).
class SeasonSelectorDialog extends StatefulWidget {
  final String title;
  final List<RequestSeason> seasons;

  const SeasonSelectorDialog({
    super.key,
    required this.title,
    required this.seasons,
  });

  static Future<List<int>?> show(
    BuildContext context, {
    required String title,
    required List<RequestSeason> seasons,
  }) {
    return showDialog<List<int>>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.8),
      builder: (_) => SeasonSelectorDialog(title: title, seasons: seasons),
    );
  }

  @override
  State<SeasonSelectorDialog> createState() => _SeasonSelectorDialogState();
}

class _SeasonSelectorDialogState extends State<SeasonSelectorDialog> {
  final Set<int> _selected = {};

  List<RequestSeason> get _sorted => [...widget.seasons]
    ..sort((a, b) => a.number.compareTo(b.number));

  /// Same filter as MediaHub SeasonSelectorModal — only seasons not yet in the library.
  List<RequestSeason> get _requestable => _sorted
      .where((s) => s.number > 0 && s.status.canRequest)
      .toList();

  bool get _allSelected =>
      _requestable.isNotEmpty && _selected.length == _requestable.length;

  void _toggle(RequestSeason season) {
    if (!season.status.canRequest) return;
    setState(() {
      if (_selected.contains(season.number)) {
        _selected.remove(season.number);
      } else {
        _selected.add(season.number);
      }
    });
  }

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_requestable.map((s) => s.number));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final seasons = _requestable;
    final hasRequestable = seasons.isNotEmpty;

    return Dialog(
      backgroundColor: AppColors.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Sélectionner les saisons',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded,
                        color: Colors.white.withValues(alpha: 0.5)),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
            if (seasons.isEmpty)
              Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
                child: Text(
                  'Aucune saison trouvée.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 14,
                  ),
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (hasRequestable)
                      TextButton(
                        onPressed: _toggleAll,
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          _allSelected
                              ? 'Tout désélectionner'
                              : 'Tout sélectionner',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                  ],
                ),
              ),
              if (!hasRequestable)
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(
                    'Toutes les saisons sont déjà disponibles ou demandées.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 13,
                    ),
                  ),
                ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: seasons.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final season = seasons[index];
                    final selectable = season.status.canRequest;
                    final selected = _selected.contains(season.number);
                    return Opacity(
                      opacity: selectable ? 1 : 0.55,
                      child: Material(
                        color: selected
                            ? AppColors.primary.withValues(alpha: 0.16)
                            : Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          onTap: selectable ? () => _toggle(season) : null,
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: selected
                                    ? AppColors.primary
                                        .withValues(alpha: 0.55)
                                    : Colors.white.withValues(alpha: 0.08),
                              ),
                            ),
                            child: Row(
                              children: [
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  width: 22,
                                  height: 22,
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? AppColors.primary
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(5),
                                    border: Border.all(
                                      color: selectable
                                          ? (selected
                                              ? AppColors.primary
                                              : Colors.white
                                                  .withValues(alpha: 0.3))
                                          : Colors.white.withValues(alpha: 0.15),
                                    ),
                                  ),
                                  child: selected
                                      ? const Icon(Icons.check_rounded,
                                          size: 16, color: Colors.white)
                                      : (!selectable
                                          ? Icon(Icons.block_rounded,
                                              size: 14,
                                              color: Colors.white
                                                  .withValues(alpha: 0.35))
                                          : null),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        season.name.isNotEmpty
                                            ? season.name
                                            : 'Saison ${season.number}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 4,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          Text(
                                            '${season.episodeCount} épisodes',
                                            style: TextStyle(
                                              color: Colors.white
                                                  .withValues(alpha: 0.4),
                                              fontSize: 12,
                                            ),
                                          ),
                                          RequestStatusBadge(
                                              status: season.status),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white.withValues(alpha: 0.7),
                    ),
                    child: const Text('Annuler'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: !hasRequestable || _selected.isEmpty
                        ? null
                        : () {
                            final list = _selected.toList()..sort();
                            Navigator.of(context).pop(list);
                          },
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.textPrimary,
                      disabledBackgroundColor:
                          AppColors.textPrimary.withValues(alpha: 0.3),
                      foregroundColor: AppColors.background,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(
                      _selected.isEmpty
                          ? 'Demander'
                          : 'Demander (${_selected.length})',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
