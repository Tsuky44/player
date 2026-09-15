import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/device_pairing.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_platform.dart';

/// Sign in by scanning a QR with the phone — the password form's neighbour on
/// the web and desktop sign-in screen (ADR-0020).
///
/// Unlike the television, this screen already knows its server: the browser was
/// served by it, and a desktop has the address field right beside this panel. So
/// it does not need direct linking — which a browser could not do anyway, a tab
/// cannot listen on a socket. It opens an ordinary server pairing, shows the
/// code as a QR, and polls; the phone scans it from inside the app and approves
/// under its own account.
class PhoneSignInPanel extends StatefulWidget {
  /// The server the pairing opens on. Null while no address is known to answer
  /// — there is nothing to open a pairing on, and the panel says so.
  final String? serverUrl;

  /// True while the address beside the panel is being checked.
  final bool probing;

  const PhoneSignInPanel({
    super.key,
    required this.serverUrl,
    this.probing = false,
  });

  /// How this device is named on the phone that approves it.
  static String get deviceName {
    if (AppPlatform.isWeb) return 'Navigateur web';
    final host = AppPlatform.hostName;
    return host.isEmpty ? AppPlatform.label : '${AppPlatform.label} · $host';
  }

  @override
  State<PhoneSignInPanel> createState() => _PhoneSignInPanelState();
}

enum _Phase { idle, opening, waiting, signingIn, failed }

class _PhoneSignInPanelState extends State<PhoneSignInPanel> {
  _Phase _phase = _Phase.idle;
  DevicePairing? _pairing;
  Timer? _pollTimer;
  Timer? _renewTimer;
  bool _polling = false;

  /// Bumped on every fresh pairing, so an answer about a code this panel has
  /// already replaced cannot sign anyone in.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (widget.serverUrl != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    }
  }

  @override
  void didUpdateWidget(PhoneSignInPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverUrl == widget.serverUrl) return;
    // A code only exists on the server that issued it: a new address means a
    // new pairing, and the old one is abandoned to its five-minute expiry.
    _cancelTimers();
    _generation++;
    if (widget.serverUrl != null) {
      _open();
    } else {
      setState(() {
        _phase = _Phase.idle;
        _pairing = null;
      });
    }
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  void _cancelTimers() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _renewTimer?.cancel();
    _renewTimer = null;
  }

  Future<void> _open() async {
    if (widget.serverUrl == null || !mounted) return;
    final generation = ++_generation;
    _cancelTimers();
    setState(() {
      _phase = _Phase.opening;
      _pairing = null;
    });

    final DevicePairing pairing;
    try {
      pairing = await context
          .read<ApiClient>()
          .startDevicePairing(deviceName: PhoneSignInPanel.deviceName);
    } catch (error) {
      debugPrint('PhoneSignInPanel: cannot open a pairing ($error)');
      if (!mounted || generation != _generation) return;
      setState(() => _phase = _Phase.failed);
      return;
    }
    if (!mounted || generation != _generation) return;

    setState(() {
      _pairing = pairing;
      _phase = _Phase.waiting;
    });

    _pollTimer = Timer.periodic(pairing.pollInterval, (_) => _check(generation));
    // Renewed rather than shown as expired: the person is looking at a sign-in
    // screen, and a code that quietly stays valid beats a button to press.
    _renewTimer = Timer(pairing.expiresIn, _open);
  }

  Future<void> _check(int generation) async {
    final pairing = _pairing;
    if (_polling || pairing == null) return;
    _polling = true;
    final DevicePairingStatus status;
    try {
      status = await context.read<ApiClient>().pollDevicePairing(pairing.deviceCode);
    } catch (_) {
      // A dropped poll is not a failed pairing: the next tick asks again.
      return;
    } finally {
      _polling = false;
    }
    if (!mounted || generation != _generation) return;

    if (status.state == DevicePairingState.expired) {
      await _open();
      return;
    }
    if (!status.isApproved || status.user == null) return;

    _cancelTimers();
    setState(() => _phase = _Phase.signingIn);

    final apiClient = context.read<ApiClient>();
    final auth = context.read<AuthProvider>();
    // The session belongs to the server that issued the code. The address field
    // may have been retyped since; the token is no good anywhere else.
    final server = widget.serverUrl;
    if (server != null && server != apiClient.baseUrl) {
      await apiClient.setConnection(server);
    }
    await auth.adoptPairedSession(token: status.token!, user: status.user!);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Connexion avec un QR code',
          textAlign: TextAlign.center,
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Scannez-le avec l’application Onyx sur un téléphone déjà connecté : '
          'Compte, puis « Connecter un appareil ».',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, height: 1.4),
        ),
        const SizedBox(height: 20),
        SizedBox(width: 216, height: 216, child: _code()),
        const SizedBox(height: 14),
        _footer(textTheme),
      ],
    );
  }

  Widget _code() {
    // Terminal and empty states before the QR: a panel with no pairing must say
    // why rather than spin (ADR-0003, conséquences).
    if (_phase == _Phase.failed) {
      return _frame(
        light: false,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off_rounded,
                size: 36, color: AppColors.textMuted),
            const SizedBox(height: 10),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Code indisponible sur ce serveur.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _open, child: const Text('Réessayer')),
          ],
        ),
      );
    }

    if (_phase == _Phase.signingIn) {
      return _frame(
        light: false,
        child: const Center(
          child: Icon(Icons.check_circle_rounded,
              size: 56, color: AppColors.success),
        ),
      );
    }

    final pairing = _pairing;
    if (widget.serverUrl == null && !widget.probing) {
      return _frame(
        light: false,
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Renseignez l’adresse du serveur pour afficher le code.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ),
        ),
      );
    }
    if (pairing == null) {
      return _frame(
        light: false,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 3)),
      );
    }

    // Real black on real white, whatever the app palette does: a camera reads
    // this, not a person.
    return _frame(
      light: true,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: QrImageView(
          data: context.read<ApiClient>().devicePairingLink(pairing.userCode),
          version: QrVersions.auto,
          backgroundColor: Colors.white,
          errorCorrectionLevel: QrErrorCorrectLevel.M,
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

  Widget _footer(TextTheme textTheme) {
    final pairing = _pairing;
    if (_phase == _Phase.signingIn) {
      return Text(
        'Connexion…',
        style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
      );
    }
    if (_phase != _Phase.waiting || pairing == null) {
      return const SizedBox(height: 20);
    }
    // The code in clear too: a phone whose camera will not focus can still type
    // it, and it is what the phone's confirmation screen shows back.
    return Text(
      'Code : ${pairing.formattedUserCode}',
      style: textTheme.bodySmall?.copyWith(
        color: AppColors.textMuted,
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _frame({required Widget child, required bool light}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: light ? Colors.white : AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: child,
    );
  }
}
