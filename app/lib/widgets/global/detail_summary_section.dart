import 'package:flutter/material.dart';

import '../../l10n/tr.dart';
import '../../models/models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';
import '../../utils/responsive.dart';
import 'detail_info_table.dart';

/// Un crédit de la fiche : « Réalisateur », « Denis Villeneuve ».
typedef DetailCredit = ({String label, String value});

/// Le corps d'une fiche sous son en-tête, partagé par toutes les fiches : les
/// crédits et les mots-clés à gauche, [infoTable] à droite sur un grand écran
/// et dessous ailleurs. Le synopsis est dans l'en-tête.
class DetailSummarySection extends StatelessWidget {
  final List<DetailCredit> credits;
  final List<String> keywords;
  final Widget infoTable;

  const DetailSummarySection({
    super.key,
    required this.credits,
    required this.infoTable,
    this.keywords = const [],
  });

  /// Le même corps pour un titre de la bibliothèque. [details] peut manquer le
  /// temps du chargement.
  factory DetailSummarySection.forDetails({
    Key? key,
    required MediaDetails? details,
  }) {
    final director = details?.director;
    return DetailSummarySection(
      key: key,
      credits: [
        if (director != null && director.isNotEmpty)
          (label: tr('Réalisateur'), value: director),
        for (final writer in details?.writers ?? const <String>[])
          (label: tr('Scénario'), value: writer),
      ],
      infoTable: details == null
          ? const SizedBox.shrink()
          : DetailInfoTable.forDetails(details),
    );
  }

  /// La colonne d'informations à droite : un quart de l'écran, assez pour
  /// les studios sur une ligne, jamais au point d'écraser le texte.
  static double _sidebarWidth(double width) =>
      (width * 0.24).clamp(340.0, 460.0);

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final hasMain = credits.isNotEmpty || keywords.isNotEmpty;
    final main = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (credits.isNotEmpty) _CreditsGrid(credits: credits),
        if (credits.isNotEmpty && keywords.isNotEmpty)
          const SizedBox(height: 24),
        if (keywords.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final word in keywords) _KeywordTag(word)],
          ),
      ],
    );
    return Padding(
      padding: AppLayout.pageInsets(context, top: 28, bottom: 8),
      child: width >= 1100
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: main),
                const SizedBox(width: 56),
                SizedBox(width: _sidebarWidth(width), child: infoTable),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (hasMain) ...[main, const SizedBox(height: 28)],
                infoTable,
              ],
            ),
    );
  }
}

class _CreditsGrid extends StatelessWidget {
  final List<DetailCredit> credits;

  const _CreditsGrid({required this.credits});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 520 ? 3 : 2;
        return Wrap(
          spacing: 24,
          runSpacing: 22,
          children: [
            for (final credit in credits)
              SizedBox(
                width: (constraints.maxWidth - (columns - 1) * 24) / columns,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(credit.label,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: AppType.body)),
                    const SizedBox(height: 4),
                    Text(credit.value,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: AppType.body)),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _KeywordTag extends StatelessWidget {
  final String keyword;

  const _KeywordTag(this.keyword);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.tag,
              size: 12, color: Colors.white.withValues(alpha: 0.4)),
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
    );
  }
}
