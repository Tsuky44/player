import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';
import '../../theme/app_colors.dart';

/// The phone's half of direct linking: point the camera at the television.
///
/// The television is offering, not asking. Its QR carries its own address on
/// the local network and a one-time code; everything the TV is missing — which
/// server, and a session on it — is here on the phone, and this screen is what
/// carries it across. Nothing goes through the server except the request that
/// mints the session, which is why this works on a television that has never
/// reached the server at all.
class TvLinkScannerScreen extends StatefulWidget {
  const TvLinkScannerScreen({super.key});

  @override
  State<TvLinkScannerScreen> createState() => _TvLinkScannerScreenState();
}

enum _LinkPhase { scanning, sending, done, failed }

class _TvLinkScannerScreenState extends State<TvLinkScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    // One format, one camera: everything else is battery and false positives.
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  _LinkPhase _phase = _LinkPhase.scanning;
  String? _error;
  String? _deviceName;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_phase != _LinkPhase.scanning) return;

    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;

      final offer = _TvOffer.parse(raw);
      if (offer == null) continue;

      setState(() {
        _phase = _LinkPhase.sending;
        _deviceName = offer.deviceName;
      });
      unawaited(_controller.stop());
      await _deliver(offer);
      return;
    }
  }

  Future<void> _deliver(_TvOffer offer) async {
    final apiClient = context.read<ApiClient>();
    try {
      final session = await apiClient.createDeviceSession();

      // A bare client: this request goes to the television on the local
      // network, not to the server, so none of the API client's base address,
      // headers or auth interceptors apply to it.
      final response = await Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 10),
          // Read the television's own answer instead of throwing on it: a
          // refused code is a message to show, not an exception.
          validateStatus: (_) => true,
        ),
      ).postUri<dynamic>(
        offer.endpoint,
        data: {
          'code': offer.code,
          'server': apiClient.baseUrl,
          'token': session.token,
          'user': session.user.toJson(),
        },
      );

      if (!mounted) return;
      if (response.statusCode != 200) {
        setState(() {
          _phase = _LinkPhase.failed;
          _error = "Le téléviseur a refusé la connexion. Affichez un nouveau "
              "code sur l'écran et réessayez.";
        });
        return;
      }
      setState(() => _phase = _LinkPhase.done);
    } on DioException catch (error) {
      if (!mounted) return;
      final timedOut = error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout;
      setState(() {
        _phase = _LinkPhase.failed;
        _error = timedOut
            ? "Le téléviseur n'a pas répondu. Vérifiez que le téléphone et le "
                'téléviseur sont sur le même réseau Wi-Fi.'
            : 'Connexion impossible. Vérifiez que le téléphone et le '
                'téléviseur sont sur le même réseau Wi-Fi.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _LinkPhase.failed;
        _error = 'Connexion impossible. Vérifiez que le téléphone et le '
            'téléviseur sont sur le même réseau Wi-Fi.';
      });
    }
  }

  void _retry() {
    setState(() {
      _phase = _LinkPhase.scanning;
      _error = null;
    });
    unawaited(_controller.start());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Connecter un téléviseur'),
        backgroundColor: Colors.transparent,
      ),
      body: switch (_phase) {
        _LinkPhase.scanning => _buildScanner(),
        _LinkPhase.sending => _buildBusy(),
        _LinkPhase.done => _buildDone(),
        _LinkPhase.failed => _buildFailed(),
      },
    );
  }

  Widget _buildScanner() {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Text(
            'Sur le téléviseur, ouvrez Onyx et laissez le code affiché. '
            'Cadrez-le ci-dessous.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, height: 1.4),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (context, error) => _buildCameraError(error),
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildCameraError(MobileScannerException error) {
    final denied =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    return _Message(
      icon: Icons.no_photography_outlined,
      title: denied ? 'Accès à la caméra refusé' : 'Caméra indisponible',
      body: denied
          ? "Autorisez l'appareil photo pour Onyx dans les réglages du "
              'téléphone, puis revenez sur cet écran.'
          : "L'appareil photo n'a pas pu démarrer sur ce téléphone.",
    );
  }

  Widget _buildBusy() {
    return _Message(
      icon: Icons.cast_connected_rounded,
      title: 'Connexion du téléviseur…',
      body: _deviceName == null
          ? 'Envoi de la session au téléviseur.'
          : 'Envoi de la session à $_deviceName.',
      busy: true,
    );
  }

  Widget _buildDone() {
    return _Message(
      icon: Icons.check_circle_outline_rounded,
      title: 'Téléviseur connecté',
      body: _deviceName == null
          ? 'Le téléviseur est connecté à votre compte.'
          : '$_deviceName est connecté à votre compte.',
      action: FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('Terminé'),
      ),
    );
  }

  Widget _buildFailed() {
    return _Message(
      icon: Icons.error_outline_rounded,
      title: 'Connexion impossible',
      body: _error ?? 'La connexion au téléviseur a échoué.',
      action: FilledButton(
        onPressed: _retry,
        child: const Text('Réessayer'),
      ),
    );
  }
}

/// A television's offer, as read out of its QR code.
class _TvOffer {
  final Uri endpoint;
  final String code;
  final String? deviceName;

  const _TvOffer({
    required this.endpoint,
    required this.code,
    this.deviceName,
  });

  /// Reads `http://<tv>:<port>/link?c=<code>&n=<name>`, and rejects anything
  /// else — this screen posts a live session to whatever it is given, so a QR
  /// that is not one of ours must not be followed.
  static _TvOffer? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;
    if (uri.scheme != 'http') return null;
    if (uri.path != '/link') return null;
    if (!uri.hasPort || uri.host.isEmpty) return null;

    final code = uri.queryParameters['c'];
    if (code == null || code.isEmpty) return null;

    final name = uri.queryParameters['n'];
    return _TvOffer(
      endpoint: uri.replace(query: null, fragment: null),
      code: code,
      deviceName: (name != null && name.trim().isNotEmpty) ? name.trim() : null,
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  final bool busy;

  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const CircularProgressIndicator(color: AppColors.primary)
            else
              Icon(icon, size: 56, color: AppColors.textSecondary),
            const SizedBox(height: 24),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textSecondary,
                height: 1.45,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: 28),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
