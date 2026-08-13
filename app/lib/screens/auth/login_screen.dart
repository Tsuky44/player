import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../widgets/global/onyx_mark.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _inviteController = TextEditingController();
  bool _isRegistering = false;
  bool _serverPrefilled = false;

  /// True while the server has no account at all. That is the only case where
  /// an account can be created without an invitation, and it produces the owner.
  bool _setupRequired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_serverPrefilled) return;
    _serverPrefilled = true;
    final apiClient = context.read<ApiClient>();
    _serverController.text = apiClient.baseUrl;
    final username = apiClient.savedUsername;
    if (username != null && username.isNotEmpty) {
      _usernameController.text = username;
    }

    // A link opened in the web build carries its token in the query string.
    // On the native apps Uri.base is not a http URL, hence the guard: there the
    // code is typed by hand, which is the only path a link cannot serve anyway.
    final invite = Uri.base.queryParameters['invite'];
    if (invite != null && invite.isNotEmpty) {
      _inviteController.text = invite;
      _isRegistering = true;
    }

    _probeSetupState();
  }

  /// Asks the server whether it is still pristine. Unauthenticated and cheap;
  /// on failure we simply keep the sign-up form hidden.
  Future<void> _probeSetupState() async {
    final apiClient = context.read<ApiClient>();
    try {
      await apiClient.setConnection(_serverController.text.trim());
      final required = await apiClient.getSetupRequired();
      if (mounted) setState(() => _setupRequired = required);
    } catch (_) {
      if (mounted) setState(() => _setupRequired = false);
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _inviteController.dispose();
    super.dispose();
  }

  /// Accepts either the raw code or the whole link pasted from a message — the
  /// two are shown side by side when a link is generated, and people paste
  /// whichever they happened to copy.
  String _inviteToken() {
    final raw = _inviteController.text.trim();
    if (!raw.contains('invite=')) return raw;
    return Uri.tryParse(raw)?.queryParameters['invite'] ?? raw;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final serverUrl = _serverController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (_isRegistering) {
      final success = await authProvider.register(
        serverUrl,
        username,
        password,
        inviteToken: _inviteToken(),
      );
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Inscription réussie ! Connectez-vous.')),
        );
        setState(() {
          _isRegistering = false;
          _inviteController.clear();
          _setupRequired = false;
        });
      }
    } else {
      await authProvider.login(serverUrl, username, password);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.55),
                  radius: 1.15,
                  colors: [
                    AppColors.surfaceElevated.withValues(alpha: 0.9),
                    AppColors.background,
                  ],
                ),
              ),
            ),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const OnyxMark(size: 48, showBeam: true),
                          const SizedBox(width: 14),
                          Text(
                            'Onyx',
                            style: textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _isRegistering
                            ? (_setupRequired
                                ? 'Créer le compte propriétaire'
                                : 'Créer un compte avec une invitation')
                            : 'Connectez-vous à votre serveur',
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 36),
                      TextFormField(
                        controller: _serverController,
                        style: const TextStyle(color: AppColors.textPrimary),
                        decoration: const InputDecoration(
                          labelText: 'Adresse du serveur',
                          hintText: 'http://192.168.1.50:8080',
                          prefixIcon: Icon(Icons.dns_rounded,
                              color: AppColors.textMuted),
                        ),
                        validator: (v) =>
                            v == null || v.trim().isEmpty ? 'Requis' : null,
                        // Re-check whether that server is pristine when the
                        // address changes: the answer belongs to the server.
                        onEditingComplete: _probeSetupState,
                      ),
                      if (_isRegistering && !_setupRequired) ...[
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _inviteController,
                          style:
                              const TextStyle(color: AppColors.textPrimary),
                          decoration: const InputDecoration(
                            labelText: 'Code d\'invitation',
                            hintText: 'Collez le lien reçu ou son code',
                            prefixIcon: Icon(Icons.mail_outline_rounded,
                                color: AppColors.textMuted),
                          ),
                          validator: (v) => v == null || v.trim().isEmpty
                              ? 'Une invitation est requise'
                              : null,
                        ),
                      ],
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _usernameController,
                        style: const TextStyle(color: AppColors.textPrimary),
                        decoration: const InputDecoration(
                          labelText: 'Nom d\'utilisateur',
                          prefixIcon: Icon(Icons.person_outline_rounded,
                              color: AppColors.textMuted),
                        ),
                        validator: (v) =>
                            v == null || v.trim().isEmpty ? 'Requis' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: true,
                        style: const TextStyle(color: AppColors.textPrimary),
                        decoration: const InputDecoration(
                          labelText: 'Mot de passe',
                          prefixIcon: Icon(Icons.lock_outline_rounded,
                              color: AppColors.textMuted),
                        ),
                        validator: (v) {
                          if (v == null || v.isEmpty) return 'Requis';
                          if (v.length < 4) return 'Minimum 4 caractères';
                          return null;
                        },
                      ),
                      if (authProvider.errorMessage != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.error.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color:
                                    AppColors.error.withValues(alpha: 0.35)),
                          ),
                          child: Text(
                            authProvider.errorMessage!,
                            style: const TextStyle(
                                color: AppColors.error, fontSize: 13),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: authProvider.isLoading ? null : _submit,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: authProvider.isLoading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.background,
                                ),
                              )
                            : Text(_isRegistering
                                ? 'S\'inscrire'
                                : 'Se connecter'),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: authProvider.isLoading
                            ? null
                            : () => setState(
                                () => _isRegistering = !_isRegistering),
                        child: Text(
                          _isRegistering
                              ? 'Déjà un compte ? Connectez-vous'
                              : (_setupRequired
                                  // Nobody exists yet: this account takes the
                                  // server over.
                                  ? 'Premier lancement : créer le compte propriétaire'
                                  : 'J\'ai un code d\'invitation'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            ),
          ],
        ),
      ),
    );
  }
}
