import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_colors.dart';
import '../../tv/tv_deferred_keyboard.dart';
import '../../tv/tv_mode.dart';

/// Le mot de passe du formulaire de connexion : un œil pour le lire, et Entrée
/// pour valider.
///
/// Entrée passe par un raccourci et non par `onFieldSubmitted` seul : au
/// clavier physique (Windows, web), la touche n'atteignait pas l'action du
/// champ et il fallait aller cliquer sur le bouton. La touche d'action du
/// clavier virtuel, elle, passe toujours par `onFieldSubmitted`.
class LoginPasswordField extends StatefulWidget {
  const LoginPasswordField({
    super.key,
    required this.keyboardKey,
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
  });

  /// Clé du [TvDeferredKeyboard], pour que le champ précédent puisse réclamer
  /// ce clavier-ci.
  final GlobalKey<TvDeferredKeyboardState> keyboardKey;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;

  @override
  State<LoginPasswordField> createState() => _LoginPasswordFieldState();
}

class _LoginPasswordFieldState extends State<LoginPasswordField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    final label =
        _visible ? 'Masquer le mot de passe' : 'Afficher le mot de passe';
    return TvDeferredKeyboard(
      key: widget.keyboardKey,
      fieldFocusNode: widget.focusNode,
      builder: (context, focusNode, canRequestFocus) => CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter): widget.onSubmit,
          const SingleActivator(LogicalKeyboardKey.numpadEnter):
              widget.onSubmit,
        },
        child: TextFormField(
          canRequestFocus: canRequestFocus,
          controller: widget.controller,
          focusNode: widget.focusNode,
          obscureText: !_visible,
          // The last field submits. On a television the button is behind the
          // keyboard, so "done" has to be a way in and not just a way out.
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) => widget.onSubmit(),
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            labelText: 'Mot de passe',
            prefixIcon: const Icon(Icons.lock_outline_rounded,
                color: AppColors.textMuted),
            // Hors téléviseur, l'œil ne prend pas le focus : un clic dessus
            // laisserait sinon le curseur quitter le champ en pleine saisie.
            // Sur un téléviseur il reste atteignable à la croix directionnelle.
            suffixIcon: ExcludeFocus(
              excluding: !TvScope.of(context),
              child: IconButton(
                tooltip: label,
                onPressed: () => setState(() => _visible = !_visible),
                icon: Icon(
                  _visible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          ),
          validator: (v) {
            if (v == null || v.isEmpty) return 'Requis';
            if (v.length < 4) return 'Minimum 4 caractères';
            return null;
          },
        ),
      ),
    );
  }
}
