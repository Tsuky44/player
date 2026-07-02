import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../navigation/catalog_navigation.dart';
import '../../providers/auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../widgets/global/media_detail_widgets.dart';
import '../../widgets/global/overlay_back_button.dart';

class PersonDetailScreen extends StatefulWidget {
  final int personTmdbId;
  final String? initialName;

  const PersonDetailScreen({
    super.key,
    required this.personTmdbId,
    this.initialName,
  });

  @override
  State<PersonDetailScreen> createState() => _PersonDetailScreenState();
}

class _PersonDetailScreenState extends State<PersonDetailScreen> {
  PersonDetails? _person;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = Provider.of<AuthProvider>(context, listen: false).apiClient;
      final person = await api.getPersonDetails(widget.personTmdbId);
      if (!mounted) return;
      setState(() {
        _person = person;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final person = _person;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _PersonHeader(
              person: person,
              fallbackName: widget.initialName,
              onBack: () => Navigator.of(context).pop(),
            ),
          ),
          if (_loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(64),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
              ),
            )
          else if (_failed || person == null)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(64),
                child: Center(
                  child: Text(
                    'Impossible de charger cette fiche.',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              ),
            )
          else ...[
            if (person.biography != null && person.biography!.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(48, 28, 48, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Biographie',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        person.biography!,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 15,
                          height: 1.6,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (person.filmography.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(48, 32, 48, 16),
                  child: Text(
                    'Filmographie',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(48, 0, 48, 48),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.crossAxisExtent;
                    final columns = (width / 160).floor().clamp(2, 8);
                    return SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 20,
                        childAspectRatio: 0.52,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final item = person.filmography[index];
                          return CatalogPosterCard(
                            item: item,
                            onTap: () => openCatalogItem(context, item),
                          );
                        },
                        childCount: person.filmography.length,
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _PersonHeader extends StatelessWidget {
  final PersonDetails? person;
  final String? fallbackName;
  final VoidCallback onBack;

  const _PersonHeader({
    required this.person,
    required this.fallbackName,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final name = person?.name ?? fallbackName ?? '';
    final backdrop = person?.backdropUrl;
    final profile = person?.profileUrl;

    return SizedBox(
      height: 380,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (backdrop != null && backdrop.isNotEmpty)
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: CachedNetworkImage(
                imageUrl: backdrop,
                fit: BoxFit.cover,
                color: Colors.black.withValues(alpha: 0.55),
                colorBlendMode: BlendMode.darken,
              ),
            )
          else
            Container(color: AppColors.surface),

          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, AppColors.background],
                stops: [0.4, 1.0],
              ),
            ),
          ),

          Positioned(
            left: 48,
            right: 48,
            bottom: 32,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 160,
                      height: 240,
                      child: profile != null && profile.isNotEmpty
                          ? CachedNetworkImage(imageUrl: profile, fit: BoxFit.cover)
                          : Container(
                              color: AppColors.surfaceElevated,
                              child: const Icon(Icons.person_rounded,
                                  size: 64, color: AppColors.textMuted),
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 32),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              height: 1.05,
                            ),
                      ),
                      if (person?.knownForDepartment != null &&
                          person!.knownForDepartment!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          _departmentLabel(person!.knownForDepartment!),
                          style: const TextStyle(
                            color: AppColors.accent,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 20,
                        runSpacing: 8,
                        children: [
                          if (_birthLine(person) != null)
                            _InfoBit(icon: Icons.cake_rounded, text: _birthLine(person)!),
                          if (person?.placeOfBirth != null &&
                              person!.placeOfBirth!.isNotEmpty)
                            _InfoBit(
                              icon: Icons.place_rounded,
                              text: person!.placeOfBirth!,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          Positioned(
            top: 4,
            left: 8,
            child: OverlayBackButton(onPressed: onBack),
          ),
        ],
      ),
    );
  }
}

class _InfoBit extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoBit({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: AppColors.textMuted),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
      ],
    );
  }
}

String _departmentLabel(String department) {
  switch (department) {
    case 'Acting':
      return 'Interprétation';
    case 'Directing':
      return 'Réalisation';
    case 'Writing':
      return 'Scénario';
    case 'Production':
      return 'Production';
    case 'Sound':
      return 'Son';
    case 'Camera':
      return 'Image';
    case 'Editing':
      return 'Montage';
    default:
      return department;
  }
}

int? _ageFrom(String birthday, String? deathday) {
  final birth = DateTime.tryParse(birthday);
  if (birth == null) return null;
  final end = (deathday != null && deathday.isNotEmpty)
      ? DateTime.tryParse(deathday) ?? DateTime.now()
      : DateTime.now();
  int age = end.year - birth.year;
  if (end.month < birth.month ||
      (end.month == birth.month && end.day < birth.day)) {
    age--;
  }
  return age >= 0 ? age : null;
}

String? _birthLine(PersonDetails? person) {
  if (person == null) return null;
  final birthday = person.birthday;
  if (birthday == null || birthday.isEmpty) return null;
  final year = birthday.split('-').first;
  if (person.deathday != null && person.deathday!.isNotEmpty) {
    final deathYear = person.deathday!.split('-').first;
    return '$year – $deathYear';
  }
  final age = _ageFrom(birthday, person.deathday);
  return age != null ? '$year ($age ans)' : year;
}
