import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/device_pairing.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_client.dart';
import '../../services/tv_link.dart';
import '../../services/tv_link_host.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_mode.dart';
import '../../utils/app_platform.dart';
import '../../theme/app_type.dart';
import '../../l10n/tr.dart';

/// Sign in by scanning a QR with the phone — the password form's neighbour on
/// the web and desktop sign-in screen (ADR-0020).
///
/// An app does what the television does: it offers. It opens a listener on the
/// local network, shows an address to itself as a QR, and the phone delivers
/// the server and a session on it — so the address field beside this panel can
/// stay empty, exactly as it does not exist on the television (ADR-0007).
///
/// A browser cannot: a tab has no socket to listen on. But it already knows its
/// server, having been served by it, so it opens an ordinary server pairing,
/// shows the code as a QR, and polls; the phone approves under its own account.
/// An app with no usable network address falls back to the same thing.
class PhoneSignInPanel extends StatefulWidget {
  /// The server a pairing opens on. Null while no address is known to answer.
  /// Direct linking ignores it: the phone is what brings the address.
  final String? serverUrl;

  /// True while the address beside the panel is being checked.
  final bool probing;

  /// Whether to offer direct linking rather than a server pairing. Null picks
  /// by platform; tests pass it because the real listener binds a socket.
  final bool? directLink;

  /// Overrides the network listener. Only tests pass this.
  final TvLinkSession Function()? createLinkSession;

  const PhoneSignInPanel({
    super.key,
    required this.serverUrl,
    this.probing = false,
    this.directLink,
    this.createLinkSession,
  });

  /// How this device is named on the phone that approves it.
  static String get deviceName {
    if (AppPlatform.isWebOS) return TvMode.deviceName;
    if (AppPlatform.isWeb) return tr('Navigateur web');
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

  /// True while this panel offers itself to the phone instead of opening a
  /// pairing on a server. Dropped for good once the offer cannot be opened.
  late bool _direct = widget.directLink ?? TvLinkHost.isSupported;
  TvLinkSession? _session;
  TvLinkOffer? _offer;

  /// Bumped on every fresh pairing, so an answer about a code this panel has
  /// already replaced cannot sign anyone in.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (_direct) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openDirect());
    } else if (widget.serverUrl != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    }
  }

  @override
  void didUpdateWidget(PhoneSignInPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The offer points at this device, whatever the address field says.
    if (_direct) return;
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
    unawaited(_session?.stop());
    super.dispose();
  }

  void _cancelTimers() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _renewTimer?.cancel();
    _renewTimer = null;
  }

  Future<void> _openDirect() async {
    if (!mounted) return;
    final generation = ++_generation;
    unawaited(_session?.stop());
    setState(() {
      _phase = _Phase.opening;
      _offer = null;
    });

    final session = (widget.createLinkSession ?? TvLinkHost.new)();
    _session = session;

    TvLinkOffer? offer;
    try {
      offer = await session.start(deviceName: PhoneSignInPanel.deviceName);
    } catch (error) {
      offer = null;
      debugPrint('PhoneSignInPanel: cannot open a link offer ($error)');
    }
    if (!mounted || generation != _generation) return;

    if (offer == null) {
      // No address to offer. The server pairing needs none of this device's,
      // only the server's — which the field beside the panel may still give.
      unawaited(session.stop());
      _session = null;
      _direct = false;
      if (widget.serverUrl != null) {
        await _open();
      } else {
        setState(() => _phase = _Phase.idle);
      }
      return;
    }

    setState(() {
      _offer = offer;
      _phase = _Phase.waiting;
    });

    final TvLinkPayload payload;
    try {
      payload = await session.linked;
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _phase = _Phase.failed);
      return;
    }
    if (!mounted || generation != _generation) return;

    setState(() => _phase = _Phase.signingIn);

    // The address first: the session is only good on the server it came from.
    final apiClient = context.read<ApiClient>();
    final auth = context.read<AuthProvider>();
    await apiClient.setConnection(payload.serverUrl);
    await auth.adoptPairedSession(token: payload.token, user: payload.user);
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
          tr('Connexion avec un QR code'),
          textAlign: TextAlign.center,
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          tr('Scannez-le avec l’application Onyx sur un téléphone déjà '
              'connecté : Compte, puis « Connecter un appareil ».'),
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
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _direct
                    ? tr('Connexion impossible.')
                    : tr('Code indisponible sur ce serveur.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: AppType.subhead),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _direct ? _openDirect : _open,
              child: Text(tr('Réessayer')),
            ),
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

    final offer = _offer;
    if (_direct) {
      if (offer == null) {
        return _frame(
          light: false,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 3)),
        );
      }
      return _qr(offer.url);
    }

    final pairing = _pairing;
    if (widget.serverUrl == null && !widget.probing) {
      return _frame(
        light: false,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              tr('Renseignez l’adresse du serveur pour afficher le code.'),
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: AppType.subhead),
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

    return _qr(context.read<ApiClient>().devicePairingLink(pairing.userCode));
  }

  /// Real black on real white, whatever the app palette does: a camera reads
  /// this, not a person.
  Widget _qr(String data) {
    return _frame(
      light: true,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: QrImageView(
          data: data,
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
        tr('Connexion…'),
        style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
      );
    }
    if (_direct && _phase == _Phase.waiting) {
      // Nothing to type and nothing that expires: the one thing that can go
      // wrong is the phone being on another network, so that is what is said.
      return Text(
        tr('Le téléphone doit être sur le même réseau que cet appareil.'),
        textAlign: TextAlign.center,
        style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
      );
    }
    if (_phase != _Phase.waiting || pairing == null) {
      return const SizedBox(height: 20);
    }
    // The code in clear too: a phone whose camera will not focus can still type
    // it, and it is what the phone's confirmation screen shows back.
    return Text(
      tr('Code : {0}', [pairing.formattedUserCode]),
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
