import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/otp.dart';
import '../../models/server_account.dart';
import '../../providers/auth_error_text.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_client.dart';
import '../../services/tv_link_host.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';
import '../../tv/tv_deferred_keyboard.dart';
import '../../tv/tv_mode.dart';
import '../../widgets/global/otp_code_dialog.dart';
import '../../widgets/global/overlay_back_button.dart';
import '../../widgets/global/profile_disc.dart';
import '../../l10n/tr.dart';
import 'login_password_field.dart';
import 'tv_login_screen.dart';

/// Ajoute une personne du serveur [server] sur cet appareil : son identifiant
/// et son mot de passe, rien d'autre.
///
/// L'adresse ne se demande pas : on ajoute quelqu'un au serveur qu'on a sous
/// les yeux dans « Qui regarde ? ». Ajouter un autre serveur reste le travail
/// de l'écran des serveurs (ADR-0078). Rend le compte ajouté, sans basculer
/// dessus : c'est l'écran appelant qui décide.
class AddUserScreen extends StatefulWidget {
  const AddUserScreen({super.key, required this.server});

  /// N'importe quel compte de ce serveur : seule son adresse sert.
  final ServerAccount server;

  @override
  State<AddUserScreen> createState() => _AddUserScreenState();
}

class _AddUserScreenState extends State<AddUserScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _usernameKeyboard = GlobalKey<TvDeferredKeyboardState>();
  final _passwordKeyboard = GlobalKey<TvDeferredKeyboardState>();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final auth = context.read<AuthProvider>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account = await _signIn(auth);
      if (!mounted) return;
      if (account == null) {
        setState(() => _busy = false);
        return;
      }
      Navigator.of(context).pop(account);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is StateError ? e.message : authErrorText(e);
      });
    }
  }

  /// La connexion, code compris quand ce compte en demande un (ADR-0041).
  /// `null` : le code a été abandonné.
  Future<ServerAccount?> _signIn(AuthProvider auth) async {
    try {
      return await auth.addServerWithPassword(
        serverUrl: widget.server.url,
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );
    } on OtpRequired catch (e) {
      if (!mounted) return null;
      final api = context.read<ApiClient>();
      final result = await showOtpLoginDialog(
        context,
        challenge: e.challenge,
        verify: (code) => api.verifyLoginOtp(e.challenge, code),
      );
      if (result == null) return null;
      return auth.adoptOtpSession(result);
    }
  }

  /// Sur une télévision, taper un mot de passe à la croix directionnelle est
  /// une épreuve : la personne peut ouvrir sa session depuis son téléphone
  /// (ADR-0003). Le compte arrivé, l'écran se referme.
  Future<void> _usePhone() async {
    final linked = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => const TvLoginScreen(addingUser: true),
    ));
    if (linked == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final byPhone = TvScope.of(context) && TvLinkHost.isSupported;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 56, 24, 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: AutofillGroup(
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _NewcomerBadge(),
                          const SizedBox(height: 24),
                          Text(
                            tr('Ajouter un utilisateur'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: AppType.title1,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            tr(
                                'Son compte sur {0}. Chacun garde sa '
                                'progression et ses listes.',
                                [widget.server.displayName]),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: AppType.body,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 28),
                          _usernameField(),
                          const SizedBox(height: 14),
                          LoginPasswordField(
                            keyboardKey: _passwordKeyboard,
                            controller: _passwordController,
                            focusNode: _passwordFocus,
                            onSubmit: _submit,
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 14),
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: AppColors.error,
                                fontSize: AppType.subhead,
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          SizedBox(
                            height: 48,
                            child: FilledButton(
                              onPressed: _busy ? null : _submit,
                              child: _busy
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : Text(tr('Ajouter')),
                            ),
                          ),
                          if (byPhone) ...[
                            const SizedBox(height: 10),
                            TextButton.icon(
                              onPressed: _busy ? null : _usePhone,
                              icon: const Icon(AppIcons.scan, size: 18),
                              label:
                                  Text(tr('Se connecter avec son téléphone')),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const Positioned(top: 0, left: 0, child: OverlayBackButton()),
          ],
        ),
      ),
    );
  }

  Widget _usernameField() {
    return TvDeferredKeyboard(
      key: _usernameKeyboard,
      fieldFocusNode: _usernameFocus,
      builder: (context, focusNode, canRequestFocus) => TextFormField(
        canRequestFocus: canRequestFocus,
        controller: _usernameController,
        focusNode: _usernameFocus,
        autofocus: !TvScope.of(context),
        autofillHints: const [AutofillHints.username],
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.next,
        // Seule façon d'avancer quand le clavier de la télévision couvre tout.
        onFieldSubmitted: (_) =>
            _passwordKeyboard.currentState?.requestKeyboard(),
        style: const TextStyle(color: AppColors.textPrimary),
        decoration: InputDecoration(
          labelText: tr('Nom d\'utilisateur'),
          prefixIcon: const Icon(Icons.person_outline_rounded,
              color: AppColors.textMuted),
        ),
        validator: (v) => v == null || v.trim().isEmpty ? tr('Requis') : null,
      ),
    );
  }
}

/// La pastille vide d'une personne qui n'est pas encore là : la même forme que
/// celles de « Qui regarde ? », un « + » à la place du visage.
class _NewcomerBadge extends StatelessWidget {
  const _NewcomerBadge();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 88,
        height: 88,
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: ProfileDisc.radiusFor(88),
          border: Border.all(color: AppColors.border),
        ),
        child: const Icon(
          AppIcons.person,
          size: 40,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}
