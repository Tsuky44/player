import 'package:flutter/material.dart';

import '../../l10n/tr.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_type.dart';
import '../../tv/tv_deferred_keyboard.dart';

/// Le prénom que le serveur accepte au plus, en caractères (miroir de
/// `sharelinks.MaxViewerNameRunes`).
const int sharedLinkViewerNameMaxLength = 40;

/// Le champ où le spectateur d'un lien donne son prénom : c'est sous lui que
/// le serveur range où il en est (ADR-0066). Le même prénom sur le même lien,
/// depuis n'importe quel appareil, retrouve la même reprise.
class SharedLinkNameField extends StatelessWidget {
  const SharedLinkNameField({
    super.key,
    required this.controller,
    required this.enabled,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final bool enabled;

  /// Nul quand un autre champ suit : Entrée passe alors à celui-là.
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TvDeferredKeyboard(
      builder: (context, focusNode, canRequestFocus) => TextField(
        controller: controller,
        focusNode: focusNode,
        canRequestFocus: canRequestFocus,
        autofocus: true,
        enabled: enabled,
        maxLength: sharedLinkViewerNameMaxLength,
        textCapitalization: TextCapitalization.words,
        textInputAction:
            onSubmitted == null ? TextInputAction.next : TextInputAction.done,
        autofillHints: const [AutofillHints.givenName],
        decoration: InputDecoration(
          labelText: tr('Votre prénom'),
          helperText: tr('Pour reprendre là où vous en êtes, '
              'même depuis un autre appareil.'),
          helperMaxLines: 2,
          counterText: '',
        ),
        onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      ),
    );
  }
}

/// « Vous regardez en tant que Marie · Changer » : qui reprend, et de quoi
/// passer la main à quelqu'un d'autre sur cet appareil.
class SharedLinkViewerLine extends StatelessWidget {
  const SharedLinkViewerLine({
    super.key,
    required this.name,
    required this.onChange,
    this.centered = false,
  });

  final String name;
  final VoidCallback? onChange;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: centered ? WrapAlignment.center : WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: [
        const Icon(Icons.person_outline_rounded,
            size: 18, color: AppColors.textMuted),
        Text(
          tr('Vous regardez en tant que {0}', [name]),
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: AppType.subhead,
          ),
        ),
        TextButton(onPressed: onChange, child: Text(tr('Changer'))),
      ],
    );
  }
}
