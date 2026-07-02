import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';

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
  bool _isRegistering = false;
  bool _serverPrefilled = false;

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
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final serverUrl = _serverController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (_isRegistering) {
      final success = await authProvider.register(serverUrl, username, password);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Inscription réussie ! Connectez-vous.')),
        );
        setState(() => _isRegistering = false);
      }
    } else {
      await authProvider.login(serverUrl, username, password);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.3, -0.5),
                radius: 1.2,
                colors: [
                  AppColors.primary.withValues(alpha: 0.15),
                  AppColors.background,
                ],
              ),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
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
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.play_arrow_rounded, size: 32, color: Colors.white),
                          ),
                          const SizedBox(width: 14),
                          Text(
                            'PLAYEUR',
                            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 3,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isRegistering ? 'Créer un compte' : 'Connectez-vous à votre serveur',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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
                          prefixIcon: Icon(Icons.dns_rounded, color: AppColors.textMuted),
                        ),
                        validator: (v) => v == null || v.trim().isEmpty ? 'Requis' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _usernameController,
                        style: const TextStyle(color: AppColors.textPrimary),
                        decoration: const InputDecoration(
                          labelText: 'Nom d\'utilisateur',
                          prefixIcon: Icon(Icons.person_outline_rounded, color: AppColors.textMuted),
                        ),
                        validator: (v) => v == null || v.trim().isEmpty ? 'Requis' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: true,
                        style: const TextStyle(color: AppColors.textPrimary),
                        decoration: const InputDecoration(
                          labelText: 'Mot de passe',
                          prefixIcon: Icon(Icons.lock_outline_rounded, color: AppColors.textMuted),
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
                            color: AppColors.error.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.error.withValues(alpha: 0.4)),
                          ),
                          child: Text(
                            authProvider.errorMessage!,
                            style: const TextStyle(color: AppColors.error, fontSize: 13),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: authProvider.isLoading ? null : _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: authProvider.isLoading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Text(_isRegistering ? 'S\'INSCRIRE' : 'SE CONNECTER'),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: authProvider.isLoading
                            ? null
                            : () => setState(() => _isRegistering = !_isRegistering),
                        child: Text(
                          _isRegistering
                              ? 'Déjà un compte ? Connectez-vous'
                              : 'Nouveau ? Créez un compte',
                          style: const TextStyle(color: AppColors.textSecondary),
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
    );
  }
}
