import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/device_pairing.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_mode.dart';
import '../../widgets/global/onyx_mark.dart';
import 'login_screen.dart';

/// Sign-in for a screen with no keyboard.
///
/// Typing a password with a D-pad is a minute of hunting across an on-screen
/// grid, and it is the first thing anyone does with the app — so the television
/// does not do it. It opens a pairing, renders the short code as a QR, and
/// waits for a phone that is already signed in to approve. The account that
/// lands on the TV is the phone's account.
///
/// The password form is still one button away: a household whose only device is
/// the television has to be able to get in, and so does the very first account
/// on a pristine server.
class TvLoginScreen extends StatefulWidget {
  const TvLoginScreen({super.key});

  @override
  State<TvLoginScreen> createState() => _TvLoginScreenState();
}

enum _PairingPhase { connecting, waiting, approved, expired, failed }

class _TvLoginScreenState extends State<TvLoginScreen> {
  final _serverController = TextEditingController();

  DevicePairing? _pairing;
  _PairingPhase _phase = _PairingPhase.connecting;
  String? _error;
  Timer? _pollTimer;
  Timer? _countdownTimer;
  Duration _remaining = Duration.zero;

  /// Guards against two polls overlapping when the network is slow — the
  /// approving poll consumes the pairing, and a second in-flight request would
  /// come back "expired" and wipe a session that was just granted.
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final apiClient = context.read<ApiClient>();
      _serverController.text = apiClient.baseUrl;
      _startPairing();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _countdownTimer?.cancel();
    _serverController.dispose();
    super.dispose();
  }

  Future<void> _startPairing() async {
    _pollTimer?.cancel();
    _countdownTimer?.cancel();

    setState(() {
      _phase = _PairingPhase.connecting;
      _error = null;
      _pairing = null;
    });

    final apiClient = context.read<ApiClient>();
    try {
      await apiClient.setConnection(_serverController.text.trim());
      final pairing =
          await apiClient.startDevicePairing(deviceName: TvMode.deviceName);
      if (!mounted) return;

      setState(() {
        _pairing = pairing;
        _phase = _PairingPhase.waiting;
        _remaining = pairing.expiresIn;
      });

      _pollTimer = Timer.periodic(pairing.pollInterval, (_) => _poll());
      _countdownTimer =
          Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _PairingPhase.failed;
        _error = _describe(error);
      });
    }
  }

  void _tick() {
    if (!mounted) return;
    final next = _remaining - const Duration(seconds: 1);
    if (next.isNegative || next == Duration.zero) {
      _expire();
      return;
    }
    setState(() => _remaining = next);
  }

  void _expire() {
    _pollTimer?.cancel();
    _countdownTimer?.cancel();
    if (!mounted) return;
    setState(() => _phase = _PairingPhase.expired);
  }

  Future<void> _poll() async {
    final pairing = _pairing;
    if (pairing == null || _polling) return;
    _polling = true;
    try {
      final status =
          await context.read<ApiClient>().pollDevicePairing(pairing.deviceCode);
      if (!mounted) return;

      if (status.isApproved && status.user != null) {
        _pollTimer?.cancel();
        _countdownTimer?.cancel();
        setState(() => _phase = _PairingPhase.approved);
        await context.read<AuthProvider>().adoptPairedSession(
              token: status.token!,
              user: status.user!,
            );
        return;
      }

      if (status.state == DevicePairingState.expired) _expire();
    } catch (_) {
      // A dropped poll is not a failed pairing — the code is still live on the
      // server, and the next tick asks again. Only the countdown ends this.
    } finally {
      _polling = false;
    }
  }

  String _describe(Object error) {
    final text = error.toString();
    if (text.contains('SocketException') ||
        text.contains('connectionError') ||
        text.contains('Failed host lookup')) {
      return "Serveur injoignable. Vérifiez l'adresse et que le serveur est allumé.";
    }
    return "Impossible de démarrer l'appairage.";
  }

  Future<void> _editServerAddress() async {
    final controller = TextEditingController(text: _serverController.text);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        title: const Text('Adresse du serveur'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: const InputDecoration(
            hintText: 'http://192.168.1.50:8080',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Valider'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (!mounted) return;
    final trimmed = result?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    _serverController.text = trimmed;
    await _startPairing();
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
        _step(1, 'Ouvrez l\'appareil photo de votre téléphone.'),
        _step(2, 'Scannez le code affiché à droite.'),
        _step(
          3,
          'Connectez-vous si besoin, puis confirmez : votre compte arrive sur la TV.',
        ),
        const SizedBox(height: 28),
        _serverLine(textTheme),
        const SizedBox(height: 20),
        Row(
          children: [
            // Material buttons are already focusable and already answer to
            // `select` through the app-wide shortcut, so they are left alone —
            // wrapping them would only add a second focus stop each.
            OutlinedButton.icon(
              onPressed: _editServerAddress,
              icon: const Icon(Icons.dns_rounded, size: 18),
              label: const Text('Changer de serveur'),
            ),
            const SizedBox(width: 12),
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

  Widget _serverLine(TextTheme textTheme) {
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
          const Icon(Icons.dns_rounded, size: 16, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              _serverController.text,
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
        SizedBox(
          width: 320,
          height: 320,
          child: _qrContent(),
        ),
        const SizedBox(height: 22),
        _codeBlock(textTheme),
        const SizedBox(height: 14),
        _status(textTheme),
      ],
    );
  }

  Widget _qrContent() {
    final pairing = _pairing;

    if (_phase == _PairingPhase.connecting || pairing == null) {
      return _qrFrame(
        child: const Center(
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
        light: false,
      );
    }

    if (_phase == _PairingPhase.failed) {
      return _qrFrame(
        light: false,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.wifi_off_rounded,
                  size: 46, color: AppColors.error),
              const SizedBox(height: 16),
              Text(
                _error ?? 'Serveur injoignable.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 18),
              ElevatedButton(
                autofocus: true,
                onPressed: _startPairing,
                child: const Text('Réessayer'),
              ),
            ],
          ),
        ),
      );
    }

    if (_phase == _PairingPhase.expired) {
      return _qrFrame(
        light: false,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.timer_off_rounded,
                  size: 46, color: AppColors.warning),
              const SizedBox(height: 16),
              const Text(
                'Ce code a expiré.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 16),
              ),
              const SizedBox(height: 18),
              ElevatedButton(
                autofocus: true,
                onPressed: _startPairing,
                child: const Text('Générer un nouveau code'),
              ),
            ],
          ),
        ),
      );
    }

    if (_phase == _PairingPhase.approved) {
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

    // A QR is read by a camera, not by a person: it needs real white quiet zone
    // around real black modules, whatever the app's own palette is doing.
    final link = context.read<ApiClient>().devicePairingLink(pairing.userCode);
    return _qrFrame(
      light: true,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: QrImageView(
          data: link,
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

  Widget _codeBlock(TextTheme textTheme) {
    final pairing = _pairing;
    if (pairing == null || _phase != _PairingPhase.waiting) {
      return const SizedBox(height: 44);
    }

    return Column(
      children: [
        Text(
          'ou saisissez ce code dans l\'app Onyx',
          style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: 6),
        Text(
          pairing.formattedUserCode,
          style: textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 6,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _status(TextTheme textTheme) {
    if (_phase != _PairingPhase.waiting) return const SizedBox(height: 20);

    final minutes = _remaining.inMinutes;
    final seconds = _remaining.inSeconds % 60;
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
          'En attente de confirmation · expire dans '
          '$minutes:${seconds.toString().padLeft(2, '0')}',
          style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }
}
