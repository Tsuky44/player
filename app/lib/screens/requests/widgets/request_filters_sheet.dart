import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/request_catalog_filters.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/global/app_network_image.dart';

/// MediaHub-style advanced filters modal (FilterModal + MediaFilters).
class RequestFiltersSheet extends StatefulWidget {
  final RequestCatalogFilters initial;
  final String mediaType;
  final ValueChanged<RequestCatalogFilters> onApply;

  const RequestFiltersSheet({
    super.key,
    required this.initial,
    required this.mediaType,
    required this.onApply,
  });

  static Future<void> show(
    BuildContext context, {
    required RequestCatalogFilters initial,
    required String mediaType,
    required ValueChanged<RequestCatalogFilters> onApply,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.85),
      builder: (_) => RequestFiltersSheet(
        initial: initial,
        mediaType: mediaType,
        onApply: onApply,
      ),
    );
  }

  @override
  State<RequestFiltersSheet> createState() => _RequestFiltersSheetState();
}

class _RequestFiltersSheetState extends State<RequestFiltersSheet> {
  late RequestCatalogFilters _draft;
  late final TextEditingController _minDurationController;
  late final TextEditingController _maxDurationController;
  late final TextEditingController _startDateController;
  late final TextEditingController _endDateController;

  List<RequestGenre> _genres = const [];
  List<RequestWatchProvider> _providers = const [];
  bool _loadingGenres = true;
  bool _loadingProviders = false;
  bool _showAllProviders = false;
  String _filterType = 'all';

  @override
  void initState() {
    super.initState();
    _draft = widget.initial;
    _filterType = widget.mediaType;
    _minDurationController = TextEditingController(text: _draft.minDuration);
    _maxDurationController = TextEditingController(text: _draft.maxDuration);
    _startDateController = TextEditingController(text: _draft.startDate);
    _endDateController = TextEditingController(text: _draft.endDate);
    _loadGenres();
    _loadProviders();
  }

  @override
  void dispose() {
    _minDurationController.dispose();
    _maxDurationController.dispose();
    _startDateController.dispose();
    _endDateController.dispose();
    super.dispose();
  }

  ApiClient get _api => context.read<ApiClient>();

  Future<void> _loadGenres() async {
    setState(() => _loadingGenres = true);
    try {
      final genres = await _api.getRequestFilterGenres(_filterType);
      if (!mounted) return;
      setState(() {
        _genres = genres;
        _loadingGenres = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingGenres = false);
    }
  }

  Future<void> _loadProviders() async {
    setState(() => _loadingProviders = true);
    try {
      final providers = await _api.getRequestWatchProviders(
        type: _filterType,
        region: _draft.watchRegion,
      );
      if (!mounted) return;
      setState(() {
        _providers = providers;
        _loadingProviders = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingProviders = false);
    }
  }

  void _reset() {
    setState(() {
      _draft = RequestCatalogFilters.defaults;
      _minDurationController.text = '';
      _maxDurationController.text = '';
      _startDateController.text = '';
      _endDateController.text = '';
    });
  }

  void _toggleGenre(int id) {
    final next = List<int>.from(_draft.genres);
    if (next.contains(id)) {
      next.remove(id);
    } else {
      next.add(id);
    }
    setState(() => _draft = _draft.copyWith(genres: next));
  }

  void _toggleProvider(int id) {
    final next = List<int>.from(_draft.watchProviders);
    if (next.contains(id)) {
      next.remove(id);
    } else {
      next.add(id);
    }
    setState(() => _draft = _draft.copyWith(watchProviders: next));
  }

  void _apply() {
    widget.onApply(_draft);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final maxW = width >= 900 ? 960.0 : width - 32;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW, maxHeight: width * 0.9),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
                  child: Row(
                    children: [
                      const Icon(Icons.tune_rounded, color: AppColors.primary),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Filtres avancés',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _reset,
                        icon: const Icon(Icons.restart_alt_rounded, size: 18),
                        label: const Text('Réinitialiser tout'),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: width >= 800
                        ? _wideLayout()
                        : _narrowLayout(),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _apply,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Voir les résultats'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _wideLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _leftColumn()),
        const SizedBox(width: 24),
        Expanded(child: _genresSection()),
        const SizedBox(width: 24),
        Expanded(child: _streamingSection()),
      ],
    );
  }

  Widget _narrowLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _leftColumn(),
        const SizedBox(height: 24),
        _genresSection(),
        const SizedBox(height: 24),
        _streamingSection(),
      ],
    );
  }

  Widget _leftColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionCard(
          title: 'Trier par',
          icon: Icons.sort_rounded,
          child: Column(
            children: [
              for (final opt in requestCatalogSortOptions)
                _sortOption(opt.value, opt.label),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _sectionCard(
          title: 'Période',
          icon: Icons.calendar_month_outlined,
          child: Column(
            children: [
              _dateField('De', _startDateController, (v) {
                setState(() => _draft = _draft.copyWith(startDate: v));
              }),
              const SizedBox(height: 12),
              _dateField('À', _endDateController, (v) {
                setState(() => _draft = _draft.copyWith(endDate: v));
              }),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _sectionCard(
          title: 'Langue',
          icon: Icons.language_rounded,
          child: DropdownButtonFormField<String>(
            value: requestCatalogLanguageOptions
                    .any((e) => e.code == _draft.language)
                ? _draft.language
                : 'all',
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: [
              for (final opt in requestCatalogLanguageOptions)
                DropdownMenuItem(value: opt.code, child: Text(opt.label)),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => _draft = _draft.copyWith(language: v));
            },
          ),
        ),
        const SizedBox(height: 16),
        _sectionCard(
          title: 'Durée (minutes)',
          icon: Icons.timer_outlined,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _minDurationController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Min',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(
                    () => _draft = _draft.copyWith(minDuration: v.trim()),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _maxDurationController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Max',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(
                    () => _draft = _draft.copyWith(maxDuration: v.trim()),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _genresSection() {
    return _sectionCard(
      title: 'Genres',
      icon: Icons.filter_alt_outlined,
      trailing: Text(
        '${_draft.genres.length} sélectionné${_draft.genres.length > 1 ? 's' : ''}',
        style: const TextStyle(
          color: AppColors.primary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      child: _loadingGenres
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final genre in _genres)
                      FilterChip(
                        label: Text(genre.name),
                        selected: _draft.genres.contains(genre.id),
                        onSelected: (_) => _toggleGenre(genre.id),
                        selectedColor:
                            AppColors.primary.withValues(alpha: 0.25),
                        checkmarkColor: AppColors.primary,
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _streamingSection() {
    final visible = _showAllProviders
        ? _providers
        : _providers.take(requestProviderPreviewLimit).toList();

    return _sectionCard(
      title: 'Streaming',
      icon: Icons.live_tv_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            value: requestCatalogRegions
                    .any((r) => r.value == _draft.watchRegion)
                ? _draft.watchRegion
                : 'FR',
            decoration: const InputDecoration(
              labelText: 'Région',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final r in requestCatalogRegions)
                DropdownMenuItem(value: r.value, child: Text(r.label)),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => _draft = _draft.copyWith(watchRegion: v));
              _loadProviders();
            },
          ),
          const SizedBox(height: 16),
          if (_loadingProviders)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_providers.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Aucun service pour cette région.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted.withValues(alpha: 0.9)),
              ),
            )
          else ...[
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1,
              ),
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final p = visible[index];
                final selected =
                    _draft.watchProviders.contains(p.providerId);
                return Material(
                  color: selected
                      ? AppColors.primary.withValues(alpha: 0.12)
                      : AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    onTap: () => _toggleProvider(p.providerId),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: selected
                              ? AppColors.primary
                              : AppColors.glassBorder,
                        ),
                      ),
                      padding: const EdgeInsets.all(6),
                      child: p.logoUrl != null
                          ? AppNetworkImage(
                              url: p.logoUrl,
                              fit: BoxFit.contain,
                              placeholder: const SizedBox.shrink(),
                              errorWidget: const SizedBox.shrink(),
                            )
                          : Center(
                              child: Text(
                                p.providerName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 9),
                              ),
                            ),
                    ),
                  ),
                );
              },
            ),
            if (_providers.length > requestProviderPreviewLimit)
              TextButton(
                onPressed: () =>
                    setState(() => _showAllProviders = !_showAllProviders),
                child: Text(
                  _showAllProviders
                      ? 'Voir moins'
                      : '+ ${_providers.length - requestProviderPreviewLimit} autres services',
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    required IconData icon,
    required Widget child,
    Widget? trailing,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const Spacer(),
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }

  Widget _sortOption(String value, String label) {
    final selected = _draft.sortBy == value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? AppColors.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => setState(() => _draft = _draft.copyWith(sortBy: value)),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? AppColors.primary : Colors.transparent,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? AppColors.primary : AppColors.textSecondary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _dateField(
    String label,
    TextEditingController controller,
    ValueChanged<String> onChanged,
  ) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'YYYY-MM-DD',
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: const Icon(Icons.calendar_today_outlined, size: 18),
          onPressed: () async {
            final value = controller.text;
            final initial = value.isNotEmpty
                ? DateTime.tryParse(value)
                : DateTime.now();
            final picked = await showDatePicker(
              context: context,
              initialDate: initial ?? DateTime.now(),
              firstDate: DateTime(1900),
              lastDate: DateTime(2100),
            );
            if (picked != null) {
              final formatted =
                  '${picked.year.toString().padLeft(4, '0')}-'
                  '${picked.month.toString().padLeft(2, '0')}-'
                  '${picked.day.toString().padLeft(2, '0')}';
              controller.text = formatted;
              onChanged(formatted);
            }
          },
        ),
      ),
      onChanged: onChanged,
    );
  }
}