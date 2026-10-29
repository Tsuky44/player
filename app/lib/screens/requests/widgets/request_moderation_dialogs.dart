import 'package:flutter/material.dart';

import '../../../l10n/tr.dart';
import '../../../theme/app_colors.dart';
import '../../../tv/tv_deferred_keyboard.dart';

/// Demande le motif d'un refus. Null : l'administrateur a renoncé ; une
/// chaîne vide : refus sans motif.
Future<String?> askDeclineReason(BuildContext context, String title) {
  return showDialog<String>(
    context: context,
    builder: (_) => _DeclineDialog(title: title),
  );
}

class _DeclineDialog extends StatefulWidget {
  const _DeclineDialog({required this.title});

  final String title;

  @override
  State<_DeclineDialog> createState() => _DeclineDialogState();
}

class _DeclineDialogState extends State<_DeclineDialog> {
  // MediaHub garde le motif dans les notes de la demande ; le serveur d'Onyx
  // en refuse au-delà de 500 caractères.
  static const _maxReason = 300;
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surfaceElevated,
      title: Text(tr('Refuser « {0} » ?', [widget.title])),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: TvDeferredKeyboard(
          builder: (context, focusNode, canRequestFocus) => TextField(
            controller: _reason,
            focusNode: focusNode,
            canRequestFocus: canRequestFocus,
            maxLength: _maxReason,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: tr('Motif (facultatif)'),
              hintText: tr('Déjà disponible ailleurs, doublon…'),
              counterText: '',
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('Annuler')),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          onPressed: () => Navigator.of(context).pop(_reason.text.trim()),
          child: Text(tr('Refuser')),
        ),
      ],
    );
  }
}

/// Confirme la suppression d'une demande dans MediaHub.
Future<bool> confirmDeleteRequest(BuildContext context, String title) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.surfaceElevated,
      title: Text(tr('Supprimer la demande « {0} » ?', [title])),
      content: Text(tr('La demande disparaît de MediaHub. Ce que Radarr ou '
          'Sonarr ont déjà téléchargé reste en place.')),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(tr('Annuler')),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(tr('Supprimer')),
        ),
      ],
    ),
  );
  return confirmed == true;
}
