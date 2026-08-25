import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../providers/auth_provider.dart';
import '../../services/api_client.dart';
import '../../services/tv_link.dart';
import '../../services/tv_link_host.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_mode.dart';
import '../../widgets/global/onyx_mark.dart';
import 'login_screen.dart';

/// Sign-in for a screen with no keyboard.
///
/// Typing a password with a D-pad is a minute of hunting across an on-screen
/// grid, and it is the first thing anyone does with the app — so the television
/// does not do it. Nor does it ask for a server address, which was the same
/// problem wearing a different hat: a freshly installed television has no
/// address, no keyboard, and no way to be told one.
///
/// It offers instead. It opens a listener on the local network, renders an
/// address to itself as a QR, and waits. The phone — which knows the server and
/// is already signed in — scans it from inside the Onyx app and delivers both
/// halves. The account that lands on the TV is the phone's account, and no
/// credential is ever typed in the living room.
///
/// The password form is still one button away: a household whose only device is
/// the television has to be able to get in, and so does the very first account
/// on a pristine server.
class TvLoginScreen extends StatefulWidget {
  /// Overrides the network listener. Only tests pass this: the real one binds a
  /// socket, which a widget test has no business doing.
  final TvLinkSession Function()? createLinkSession;

  const TvLoginScreen({super.key, this.createLinkSession});

  @override
  State<TvLoginScreen> createState() => _TvLoginScreenState();
}

enum _LinkPhase { opening, waiting, linked, failed }

class _TvLoginScreenState extends State<TvLoginScreen> {
  TvLinkSession? _session;
  TvLinkOffer? _offer;
  _LinkPhase _phase = _LinkPhase.opening;
  String? _error;

  /// Bumped every time a fresh offer is opened, so the delivery of an offer the
  /// user has already replaced cannot sign the television in behind their back.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startLink());
  }

  @override
  void dispose() {
    unawaited(_session?.stop());
    super.dispose();
  }

  Future<void> _startLink() async {
    final generation = ++_generation;
    unawaited(_session?.stop());

    setState(() {
      _phase = _LinkPhase.opening;
      _error = null;
      _offer = null;
    });

    final session = (widget.createLinkSession ?? TvLinkHost.new)();
    _session = session;

    TvLinkOffer? offer;
    try {
      offer = await session.start(deviceName: TvMode.deviceName);
    } catch (error) {
      offer = null;
      debugPrint('TvLoginScreen: cannot open a link offer ($error)');
    }
    if (!mounted || generation != _generation) return;

    if (offer == null) {
      setState(() {
        _phase = _LinkPhase.failed;
        _error = 'Ce téléviseur n’est pas connecté au réseau. Vérifiez le '
            'Wi-Fi ou le câble Ethernet, puis réessayez.';
      });
      return;
    }

    setState(() {
      _offer = offer;
      _phase = _LinkPhase.waiting;
    });

    unawaited(_awaitDelivery(session, generation));
  }

  Future<void> _awaitDelivery(TvLinkSession session, int generation) async {
    final TvLinkPayload payload;
    try {
      payload = await session.linked;
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _phase = _LinkPhase.failed;
        _error = 'La connexion depuis le téléphone a échoué.';
      });
      return;
    }
    if (!mounted || generation != _generation) return;

    setState(() => _phase = _LinkPhase.linked);

    // The address first: everything the session is good for lives on that
    // server, and adopting a session while the client still points somewhere
    // else would authenticate against the wrong host.
    final apiClient = context.read<ApiClient>();
    await apiClient.setConnection(payload.serverUrl);
    if (!mounted) return;
    await context.read<AuthProvider>().adoptPairedSession(
          token: payload.token,
          user: payload.user,
        );
  }

  void _openPasswordForm() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                  center: const Alignment(-0.35, -0.4),
                  radius: 1.2,
                  colors: [
                    AppColors.surfaceElevated.withValues(alpha: 0.9),
                    AppColors.background,
                  ],
                ),
              ),
            ),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 56,
                  vertical: 32,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 980),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Below ~820 px the QR and the instructions stop fitting
                      // side by side. That is not a television, but the screen
                      // is reachable from a phone through the TV-mode override.
                      final stacked = constraints.maxWidth < 820;
                      final instructions = _instructions(textTheme);
                      final qr = _qrPanel(textTheme);

                      if (stacked) {
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            instructions,
                            const SizedBox(height: 36),
                            qr,
                          ],
                        );
                      }

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(child: instructions),
                          const SizedBox(width: 56),
                          qr,
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _instructions(TextTheme textTheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const OnyxMark(size: 52, showBeam: true),
            const SizedBox(width: 16),
            Text(
              'Onyx',
              style: textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        Text(
          'Connectez votre téléviseur',
          style: textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 18),
        // The app, not the camera: the phone has to be signed in for this to
        // work, and its camera app cannot reach the account. Saying so in step
        // one is what stops the scan that opens a browser page instead.
        _step(1, 'Ouvrez l’application Onyx sur votre téléphone.'),
        _step(2, 'Allez dans Compte, puis « Connecter un téléviseur ».'),
        _step(3, 'Scannez le code affiché ici. C’est tout : ni adresse de '
            'serveur, ni mot de passe à saisir.'),
        const SizedBox(height: 28),
        _addressLine(textTheme),
        const SizedBox(height: 20),
        // A Wrap, not a Row: side by side these overflow the column on the
        // narrow layout, and a clipped button on a screen driven by a remote is
        // a dead end.
        //
        // Material buttons are already focusable and already answer to `select`
        // through the app-wide shortcut, so they are left alone — wrapping them
        // would only add a second focus stop each.
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              onPressed: _openPasswordForm,
              child: const Text('Utiliser un mot de passe'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _step(int number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.16),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
            ),
            child: Text(
              '$number',
              style: const TextStyle(
                color: AppColors.accentMuted,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 16,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// This television's own address, not a server's — there is no server here
  /// yet, and that is the point. It is shown so a user who scans and sees
  /// nothing happen can check the two devices are on the same network.
  Widget _addressLine(TextTheme textTheme) {
    final offer = _offer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.tv_rounded, size: 16, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              offer == null
                  ? 'Ouverture du code…'
                  : '${TvMode.deviceName} · ${offer.host}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _qrPanel(TextTheme textTheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Square for the QR, taller when a message has to fit. Pinning the
        // height clipped the failure panel, which is exactly the state that has
        // the most to say and the button the user needs.
        ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: 320,
            maxWidth: 320,
            minHeight: 320,
          ),
          child: _qrContent(),
        ),
        const SizedBox(height: 22),
        _status(textTheme),
      ],
    );
  }

  Widget _qrContent() {
    // Terminal states first. The other order — "no offer yet" tested first —
    // is how this screen once put a failed television on a spinner forever,
    // with the error and its retry button rendered nowhere.
    if (_phase == _LinkPhase.failed) {
      return _qrFrame(
        light: false,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.wifi_off_rounded,
                  size: 46, color: AppColors.error),
              const SizedBox(height: 16),
              Text(
                _error ?? 'Connexion impossible.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 18),
              ElevatedButton(
                autofocus: true,
                onPressed: _startLink,
                child: const Text('Réessayer'),
              ),
            ],
          ),
        ),
      );
    }

    if (_phase == _LinkPhase.linked) {
      return _qrFrame(
        light: false,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_rounded,
                  size: 64, color: AppColors.success),
              SizedBox(height: 16),
              Text(
                'Compte connecté',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 18),
              ),
            ],
          ),
        ),
      );
    }

    final offer = _offer;
    if (offer == null) {
      return _qrFrame(
        light: false,
        child: const Center(
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      );
    }

    // A QR is read by a camera, not by a person: it needs real white quiet zone
    // around real black modules, whatever the app's own palette is doing.
    return _qrFrame(
      light: true,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: QrImageView(
          data: offer.url,
          // 320 minus the frame's own padding: the module grid has to be a
          // stable size now that the panel grows with its content.
          size: 284,
          version: QrVersions.auto,
          backgroundColor: Colors.white,
          // Error correction high: the code is photographed off a glossy panel,
          // often at an angle, with the room's lights in it.
          errorCorrectionLevel: QrErrorCorrectLevel.H,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Colors.black,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Colors.black,
          ),
        ),
      ),
    );
  }

  Widget _qrFrame({required Widget child, required bool light}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: light ? Colors.white : AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: child,
    );
  }

  Widget _status(TextTheme textTheme) {
    if (_phase != _LinkPhase.waiting) return const SizedBox(height: 20);

    // No countdown: nothing expires here. The code is only good while this
    // screen is up, and the listener behind it dies with the screen — so the
    // honest status is "waiting", not a clock the user has to beat.
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Text(
          'En attente de votre téléphone…',
          style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }
}
