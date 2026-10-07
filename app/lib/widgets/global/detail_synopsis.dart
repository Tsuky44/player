import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_type.dart';
import '../../tv/tv_focus.dart';
import '../../l10n/tr.dart';

/// Le synopsis de l'en-tête d'une fiche, coupé à [maxLines].
///
/// La fiche le répétait en entier plus bas dès qu'il était coupé : deux fois
/// le même paragraphe sur une page. Il n'existe plus qu'ici ; quand il ne
/// tient pas, les points de suspension se touchent et ouvrent le texte
/// complet ([showSynopsisDialog]). Quand il tient, c'est du texte simple —
/// rien à activer, donc rien que la télécommande doive traverser.
class DetailSynopsis extends StatelessWidget {
  /// Titre du média, repris en tête du texte complet.
  final String title;
  final String overview;
  final int maxLines;

  const DetailSynopsis({
    super.key,
    required this.title,
    required this.overview,
    required this.maxLines,
  });

  static const TextStyle style = TextStyle(
    color: AppColors.textSecondary,
    fontSize: AppType.body,
    height: 1.55,
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final text = Text(
          overview,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
        if (!_truncated(context, constraints.maxWidth)) return text;

        void open() =>
            showSynopsisDialog(context, title: title, overview: overview);
        return TvFocusable(
          onSelect: open,
          // Un paragraphe qui grossit déborderait sur les puces et les actions.
          focusScale: 1.0,
          borderRadius: BorderRadius.circular(6),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: open,
              child: Semantics(
                button: true,
                hint: tr('Lire le synopsis complet'),
                child: text,
              ),
            ),
          ),
        );
      },
    );
  }

  /// Mesuré à la largeur réellement accordée, dans la police du thème : c'est
  /// le même calcul que celui du [Text] affiché, donc la même réponse.
  bool _truncated(BuildContext context, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(
        text: overview,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      maxLines: maxLines,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    final truncated = painter.didExceedMaxLines;
    painter.dispose();
    return truncated;
  }
}

/// Le synopsis en entier, dans une fenêtre qui défile s'il dépasse l'écran.
Future<void> showSynopsisDialog(
  BuildContext context, {
  required String title,
  required String overview,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Text(
          overview,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: AppType.callout,
            height: 1.6,
          ),
        ),
      ),
      actions: [
        TextButton(
          // La télécommande arrive sur le seul geste possible.
          autofocus: true,
          onPressed: () => Navigator.pop(context),
          child: Text(tr('Fermer')),
        ),
      ],
    ),
  );
}
