import 'dart:async';

import 'package:dio/dio.dart' show DioException;
import 'package:flutter/material.dart';
import '../../tv/tv_deferred_keyboard.dart';
import 'package:provider/provider.dart';
import '../../models/server_account.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_client.dart';
import '../../services/server_discovery.dart';
import '../../theme/app_colors.dart';
import '../../widgets/global/onyx_mark.dart';

/// Les trois façons d'arriver sur un serveur.
///
/// [request] est celle qu'ADR-0013 ajoute : on ne possède ni compte ni
/// invitation, alors on sonne et on attend qu'un administrateur ouvre.
enum _LoginMode { signIn, register, request }

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

  /// One node per field, so the keyboard's "next" key has somewhere to go.
  /// Without them the on-screen keyboard is a dead end on a television: it
  /// covers the form, and there is no pointer to tap the field underneath.
  final _serverFocus = FocusNode();
  final _inviteFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();

  /// Un enchaînement de champs ne peut plus se contenter de demander le focus.
  ///
  /// Sur un téléviseur, le champ suivant est **hors du parcours** tant que
  /// personne n'a réclamé son clavier — c'est ce qui empêche la croix
  /// directionnelle de l'ouvrir en passant. Enchaîner veut donc dire le
  /// réclamer pour lui, ce que seule la clé du champ permet.
  final _inviteKeyboard = GlobalKey<TvDeferredKeyboardState>();
  final _usernameKeyboard = GlobalKey<TvDeferredKeyboardState>();
  final _passwordKeyboard = GlobalKey<TvDeferredKeyboardState>();

  _LoginMode _mode = _LoginMode.signIn;
  bool _serverPrefilled = false;

  /// Motif joint à une demande d'accès. Décoratif, mais c'est la seule chose
  /// qui distingue un inconnu d'un autre sur l'écran de l'administrateur.
  final _messageController = TextEditingController();

  /// Le sondage des demandes en attente. Sur cet écran il a un sens précis :
  /// la personne est devant, elle attend d'être acceptée, et l'app doit la
  /// faire entrer d'elle-même le moment venu.
  Timer? _poll;

  /// True while the network sweep runs. This form is the fallback path — the
  /// one a television reaches when it has nobody with a phone to link it — and
  /// typing an address on it is the worst minute in the app, so the sweep is
  /// offered right under the field.
  bool _discovering = false;

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
      _mode = _LoginMode.register;
    }

    _probeSetupState();
    // Une demande partie d'ici a pu être acceptée entre-temps : c'est le
    // premier écran que voit l'app, donc le premier endroit où le vérifier.
    _startPollingIfPending();
  }

  /// Sweeps the local network and fills the address in with what answers.
  ///
  /// Cheaper than it sounds — a TCP connect weeds out the addresses that are
  /// not there — and vastly cheaper than hunting characters on an on-screen
  /// keyboard with a D-pad.
  Future<void> _discoverServer() async {
    if (_discovering) return;
    setState(() => _discovering = true);
    String? found;
    try {
      found = await ServerDiscovery.find();
    } catch (_) {
      found = null;
    }
    if (!mounted) return;
    setState(() => _discovering = false);

    if (found == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Aucun serveur Onyx trouvé sur ce réseau.'),
        ),
      );
      return;
    }
    _serverController.text = found;
    await _probeSetupState();
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
    _messageController.dispose();
    _poll?.cancel();
    _serverFocus.dispose();
    _inviteFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  /// Whether the invitation field is on screen — it is what follows the server
  /// address when an account is being created against an established server.
  bool get _invitingShown =>
      _mode == _LoginMode.register && !_setupRequired;

  /// La demande en attente pour l'adresse affichée, s'il y en a une.
  PendingAccessRequest? _pendingFor(AuthProvider auth) {
    final url = ServerAccount.normalizeUrl(_serverController.text);
    for (final request in auth.pendingAccessRequests) {
      if (request.url == url) return request;
    }
    return auth.pendingAccessRequests.isEmpty
        ? null
        : auth.pendingAccessRequests.first;
  }

  /// Interroge le serveur jusqu'à ce qu'on soit accepté — auquel cas
  /// [AuthProvider] ouvre la session et cet écran disparaît de lui-même.
  void _startPollingIfPending() {
    final auth = context.read<AuthProvider>();
    if (auth.pendingAccessRequests.isEmpty) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    _poll ??= Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted) return;
      await context.read<AuthProvider>().refreshAccessRequests();
      if (mounted) _startPollingIfPending();
    });
  }

  /// Passe au champ suivant, clavier compris.
  ///
  /// La touche d'action du clavier virtuel est le seul moyen d'avancer dans ce
  /// formulaire sur un téléviseur : le clavier occupe tout l'écran, donc ni le
  /// champ suivant ni le bouton de validation ne sont atteignables tant qu'il
  /// est ouvert. `onEditingComplete` reste à proscrire ici — il *remplace* la
  /// gestion de cette touche au lieu de s'y ajouter.
  void _focusNext(GlobalKey<TvDeferredKeyboardState> field) {
    if (mounted) field.currentState?.requestKeyboard();
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
    // A television's keyboard is full screen: leaving it up hides the result,
    // error message included.
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final serverUrl = _serverController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    switch (_mode) {
      case _LoginMode.register:
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
            _mode = _LoginMode.signIn;
            _inviteController.clear();
            _setupRequired = false;
          });
        }

      case _LoginMode.request:
        try {
          await authProvider.requestAccess(
            serverUrl: serverUrl,
            username: username,
            password: password,
            message: _messageController.text.trim(),
          );
          if (!mounted) return;
          setState(() => _mode = _LoginMode.signIn);
          _startPollingIfPending();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Demande envoyée. Vous serez connecté dès qu’elle sera acceptée.'),
            ),
          );
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_requestErrorText(e)),
            backgroundColor: AppColors.error,
          ));
        }

      case _LoginMode.signIn:
        await authProvider.login(serverUrl, username, password);
    }
  }

  /// Le serveur écrit ses refus en français (nom pris, serveur vierge, file
  /// pleine) : les relayer tels quels vaut mieux que de les traduire à
  /// l'aveugle.
  String _requestErrorText(Object error) {
    final response = error is DioException ? error.response : null;
    final data = response?.data;
    if (data is Map && data['error'] != null) return data['error'].toString();
    return 'Demande impossible : vérifiez l’adresse du serveur.';
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    final textTheme = Theme.of(context).textTheme;
    final pending = _pendingFor(authProvider);

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
                        switch (_mode) {
                          _LoginMode.register => _setupRequired
                              ? 'Créer le compte propriétaire'
                              : 'Créer un compte avec une invitation',
                          _LoginMode.request =>
                            'Demander l’accès à ce serveur',
                          _LoginMode.signIn =>
                            'Connectez-vous à votre serveur',
                        },
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 36),
                      TvDeferredKeyboard(
                        fieldFocusNode: _serverFocus,
                        builder: (context, focusNode, canRequestFocus) => TextFormField(
                          canRequestFocus: canRequestFocus,
                          controller: _serverController,
                          focusNode: _serverFocus,
                          keyboardType: TextInputType.url,
                          textInputAction: TextInputAction.next,
                          style: const TextStyle(color: AppColors.textPrimary),
                          decoration: const InputDecoration(
                            labelText: 'Adresse du serveur',
                            hintText: 'http://192.168.1.50:8080',
                            prefixIcon: Icon(Icons.dns_rounded,
                                color: AppColors.textMuted),
                          ),
                          validator: (v) =>
                              v == null || v.trim().isEmpty ? 'Requis' : null,
                          // This used to be an `onEditingComplete`, which is the
                          // callback that *replaces* Flutter's own handling of the
                          // keyboard's action key. So "next" ran the probe and did
                          // nothing else: focus never moved, the keyboard never
                          // closed, and on a television — where it covers the form
                          // and there is no pointer to tap the field underneath —
                          // the password could not be reached at all.
                          //
                          // Re-check whether that server is pristine when the
                          // address changes: the answer belongs to the server.
                          onFieldSubmitted: (_) {
                            _probeSetupState();
                            _focusNext(_invitingShown
                                ? _inviteKeyboard
                                : _usernameKeyboard);
                          },
                                              ),
                      ),
                      if (ServerDiscovery.isSupported)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _discovering ? null : _discoverServer,
                            icon: _discovering
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.travel_explore_rounded,
                                    size: 18),
                            label: Text(_discovering
                                ? 'Recherche…'
                                : 'Détecter le serveur sur le réseau'),
                          ),
                        ),
                      if (_invitingShown) ...[
                        const SizedBox(height: 16),
                        TvDeferredKeyboard(
                          key: _inviteKeyboard,
                          fieldFocusNode: _inviteFocus,
                          builder: (context, focusNode, canRequestFocus) => TextFormField(
                            canRequestFocus: canRequestFocus,
                            controller: _inviteController,
                            focusNode: _inviteFocus,
                            textInputAction: TextInputAction.next,
                            onFieldSubmitted: (_) => _focusNext(_usernameKeyboard),
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
                        ),
                      ],
                      const SizedBox(height: 16),
                      TvDeferredKeyboard(
                        key: _usernameKeyboard,
                        fieldFocusNode: _usernameFocus,
                        builder: (context, focusNode, canRequestFocus) => TextFormField(
                          canRequestFocus: canRequestFocus,
                          controller: _usernameController,
                          focusNode: _usernameFocus,
                          textInputAction: TextInputAction.next,
                          onFieldSubmitted: (_) => _focusNext(_passwordKeyboard),
                          style: const TextStyle(color: AppColors.textPrimary),
                          decoration: const InputDecoration(
                            labelText: 'Nom d\'utilisateur',
                            prefixIcon: Icon(Icons.person_outline_rounded,
                                color: AppColors.textMuted),
                          ),
                          validator: (v) =>
                              v == null || v.trim().isEmpty ? 'Requis' : null,
                                              ),
                      ),
                      const SizedBox(height: 16),
                      TvDeferredKeyboard(
                        key: _passwordKeyboard,
                        fieldFocusNode: _passwordFocus,
                        builder: (context, focusNode, canRequestFocus) => TextFormField(
                          canRequestFocus: canRequestFocus,
                          controller: _passwordController,
                          focusNode: _passwordFocus,
                          obscureText: true,
                          // The last field submits. On a television the button is
                          // behind the keyboard, so "done" has to be a way in and
                          // not just a way out.
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => _submit(),
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
                      ),
                      if (_mode == _LoginMode.request) ...[
                        const SizedBox(height: 16),
                        TvDeferredKeyboard(
                          builder: (context, focusNode, canRequestFocus) =>
                              TextFormField(
                            focusNode: focusNode,
                            canRequestFocus: canRequestFocus,
                            controller: _messageController,
                            maxLength: 280,
                            style:
                                const TextStyle(color: AppColors.textPrimary),
                            decoration: const InputDecoration(
                              labelText: 'Message (facultatif)',
                              hintText: 'Dites qui vous êtes',
                              prefixIcon: Icon(
                                  Icons.chat_bubble_outline_rounded,
                                  color: AppColors.textMuted),
                            ),
                          ),
                        ),
                      ],
                      if (pending != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color:
                                    AppColors.primary.withValues(alpha: 0.35)),
                          ),
                          child: Row(
                            children: [
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Demande envoyée à ${pending.prettyHost} pour '
                                  '« ${pending.username} ». La connexion se fera '
                                  'toute seule dès qu’un administrateur aura '
                                  'accepté.',
                                  style: const TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 12),
                                ),
                              ),
                              TextButton(
                                onPressed: () async {
                                  await context
                                      .read<AuthProvider>()
                                      .abandonAccessRequest(pending);
                                  if (mounted) _startPollingIfPending();
                                },
                                child: const Text('Annuler'),
                              ),
                            ],
                          ),
                        ),
                      ],
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
                            : Text(switch (_mode) {
                                _LoginMode.register => 'S\'inscrire',
                                _LoginMode.request => 'Envoyer la demande',
                                _LoginMode.signIn => 'Se connecter',
                              }),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: authProvider.isLoading
                            ? null
                            : () => setState(() {
                                  _mode = _mode == _LoginMode.signIn
                                      ? _LoginMode.register
                                      : _LoginMode.signIn;
                                }),
                        child: Text(
                          _mode == _LoginMode.signIn
                              ? (_setupRequired
                                  // Nobody exists yet: this account takes the
                                  // server over.
                                  ? 'Premier lancement : créer le compte propriétaire'
                                  : 'J\'ai un code d\'invitation')
                              : 'Déjà un compte ? Connectez-vous',
                        ),
                      ),
                      // Sans invitation et sans compte, il reste la sonnette :
                      // demander à quelqu'un du serveur de vous ouvrir. Masqué
                      // sur un serveur vierge, qui n'a encore personne pour
                      // répondre.
                      if (!_setupRequired && _mode != _LoginMode.request)
                        TextButton(
                          onPressed: authProvider.isLoading
                              ? null
                              : () => setState(
                                  () => _mode = _LoginMode.request),
                          child: const Text(
                              'Pas d’invitation ? Demander l’accès'),
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
