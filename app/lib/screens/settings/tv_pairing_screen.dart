import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/device_pairing.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';

/// The phone's half of the TV sign-in.
///
/// Reached two ways, and they are the same screen because they end in the same
/// decision. Scanning the QR opens the web app with `?tv=CODE`, which lands
/// here with the code already filled; anyone without a camera handy opens it
/// from the account menu and types the eight characters off the television.
///
/// Approving mints a session for *this* account on the server. That is the
/// whole security model: the TV never sees a password, and it can never get an
/// account other than the one that pressed the button here.
class TvPairingScreen extends StatefulWidget {
  /// Code lifted from the scanned link, when there was one.
  final String? initialCode;

  const TvPairingScreen({super.key, this.initialCode});

  @override
  State<TvPairingScreen> createState() => _TvPairingScreenState();
}

enum _ApprovalPhase { entering, looking, confirming, approving, done, denied }

class _TvPairingScreenState extends State<TvPairingScreen> {
  final _codeController = TextEditingController();

  _ApprovalPhase _phase = _ApprovalPhase.entering;
  DevicePairingRequest? _request;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialCode?.trim();
    if (initial != null && initial.isNotEmpty) {
      _codeController.text = _format(initial);
      WidgetsBinding.instance.addPostFrameCallback((_) => _lookup());
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  /// Strips the separator and the case the user may have typed, matching what
  /// the server normalises to.
  String _normalize(String raw) {
    final buffer = StringBuffer();
    for (final unit in raw.toUpperCase().codeUnits) {
      final isDigit = unit >= 0x30 && unit <= 0x39;
      final isLetter = unit >= 0x41 && unit <= 0x5A;
      if (isDigit || isLetter) buffer.writeCharCode(unit);
    }
    return buffer.toString();
  }

  String _format(String raw) {
    final code = _normalize(raw);
    if (code.length != 8) return code;
    return '${code.substring(0, 4)}-${code.substring(4)}';
  }

  Future<void> _lookup() async {
    final code = _normalize(_codeController.text);
    if (code.length != 8) {
      setState(() => _error = 'Le code fait 8 caractères.');
      return;
    }

    setState(() {
      _phase = _ApprovalPhase.looking;
      _error = null;
    });

    try {
      final request = await context.read<ApiClient>().lookupDevicePairing(code);
      if (!mounted) return;
      setState(() {
        _request = request;
        _phase = _ApprovalPhase.confirming;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _ApprovalPhase.entering;
        _error = 'Code inconnu ou expiré. Vérifiez ce qui est affiché sur la TV.';
      });
    }
  }

  Future<void> _approve() async {
    final request = _request;
    if (request == null) return;

    setState(() {
      _phase = _ApprovalPhase.approving;
      _error = null;
    });

    try {
      await context.read<ApiClient>().approveDevicePairing(request.userCode);
      if (!mounted) return;
      setState(() => _phase = _ApprovalPhase.done);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _ApprovalPhase.confirming;
        _error = 'La confirmation a échoué. Le code a peut-être expiré.';
      });
    }
  }

  Future<void> _deny() async {
    final request = _request;
    if (request == null) return;
    try {
      await context.read<ApiClient>().denyDevicePairing(request.userCode);
    } catch (_) {
      // The code dies on its own in five minutes either way.
    }
    if (!mounted) return;
    setState(() => _phase = _ApprovalPhase.denied);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Connecter une TV')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: _body(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    switch (_phase) {
      case _ApprovalPhase.entering:
      case _ApprovalPhase.looking:
        return _codeForm();
      case _ApprovalPhase.confirming:
      case _ApprovalPhase.approving:
        return _confirmation();
      case _ApprovalPhase.done:
        return _outcome(
          icon: Icons.check_circle_rounded,
          color: AppColors.success,
          title: 'Téléviseur connecté',
          detail:
              'Votre compte est maintenant actif sur ${_request?.deviceName ?? 'la TV'}.',
        );
      case _ApprovalPhase.denied:
        return _outcome(
          icon: Icons.cancel_rounded,
          color: AppColors.textMuted,
          title: 'Demande refusée',
          detail: 'Le code a été annulé. Rien n\'a été connecté.',
        );
    }
  }

  Widget _codeForm() {
    final busy = _phase == _ApprovalPhase.looking;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.tv_rounded, size: 52, color: AppColors.textSecondary),
        const SizedBox(height: 18),
        Text(
          'Saisissez le code affiché sur votre téléviseur',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _codeController,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          textAlign: TextAlign.center,
          maxLength: 9, // eight characters plus the separator
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 26,
            letterSpacing: 6,
            fontWeight: FontWeight.w700,
          ),
          inputFormatters: [
            // Re-inserting the dash as the user types keeps what they see
            // identical to what the TV shows, which is what they are checking.
            TextInputFormatter.withFunction((oldValue, newValue) {
              final formatted = _format(newValue.text);
              return TextEditingValue(
                text: formatted,
                selection: TextSelection.collapsed(offset: formatted.length),
              );
            }),
          ],
          decoration: const InputDecoration(
            hintText: 'ABCD-EFGH',
            counterText: '',
          ),
          onSubmitted: (_) => _lookup(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.error, fontSize: 13),
          ),
        ],
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: busy ? null : _lookup,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.background,
                  ),
                )
              : const Text('Continuer'),
        ),
      ],
    );
  }

  Widget _confirmation() {
    final request = _request!;
    final username = context.read<AuthProvider>().currentUser?.username ?? '';
    final busy = _phase == _ApprovalPhase.approving;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.cast_connected_rounded,
            size: 52, color: AppColors.accentMuted),
        const SizedBox(height: 18),
        Text(
          request.deviceName,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          'demande à se connecter avec votre compte « $username ».',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary, height: 1.4),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border:
                Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
          ),
          child: const Text(
            'N\'acceptez que si ce code vient bien de votre téléviseur, '
            'et qu\'il est affiché en ce moment.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.error, fontSize: 13),
          ),
        ],
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: busy ? null : _approve,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.background,
                  ),
                )
              : const Text('Autoriser ce téléviseur'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: busy ? null : _deny,
          child: const Text('Refuser'),
        ),
      ],
    );
  }

  Widget _outcome({
    required IconData icon,
    required Color color,
    required String title,
    required String detail,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(icon, size: 64, color: color),
        const SizedBox(height: 18),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 10),
        Text(
          detail,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary, height: 1.4),
        ),
        const SizedBox(height: 28),
        ElevatedButton(
          onPressed: () => Navigator.of(context).maybePop(),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: const Text('Terminé'),
        ),
      ],
    );
  }
}
