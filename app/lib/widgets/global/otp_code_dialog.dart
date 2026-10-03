import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/otp.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_deferred_keyboard.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';

/// Validation en deux étapes (ADR-0041) : le dialogue qui demande un code,
/// précédé du QR code quand il s'agit d'en configurer un, et suivi des codes
/// de secours quand le serveur vient d'en tirer.
///
/// Le même pour la connexion, l'ajout d'un serveur et les réglages du compte :
/// seul [verify] change. Il rend son résultat, ou null si l'utilisateur a
/// abandonné.
Future<T?> showOtpCodeDialog<T>(
  BuildContext context, {
  required String title,
  required Future<T> Function(String code) verify,
  OtpSetup? setup,
  bool acceptsRecoveryCode = false,
  List<String> Function(T result)? recoveryCodesOf,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _OtpCodeDialog<T>(
      title: title,
      verify: verify,
      setup: setup,
      acceptsRecoveryCode: acceptsRecoveryCode,
      recoveryCodesOf: recoveryCodesOf,
    ),
  );
}

/// Montre des codes de secours qui viennent d'être tirés.
Future<void> showRecoveryCodesDialog(BuildContext context, List<String> codes) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.surfaceElevated,
      title: const Text('Codes de secours'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: RecoveryCodesView(codes: codes),
      ),
      actions: [
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('J’ai noté mes codes'),
        ),
      ],
    ),
  );
}

/// La connexion arrêtée sur un code : configuration imposée ou simple code.
Future<OtpLoginResult?> showOtpLoginDialog(
  BuildContext context, {
  required OtpChallenge challenge,
  required Future<OtpLoginResult> Function(String code) verify,
}) {
  return showOtpCodeDialog<OtpLoginResult>(
    context,
    title: challenge.setup
        ? 'Configurer la validation en deux étapes'
        : 'Code de vérification',
    setup: challenge.setup
        ? OtpSetup(secret: challenge.secret, uri: challenge.uri)
        : null,
    acceptsRecoveryCode: !challenge.setup,
    verify: verify,
    recoveryCodesOf: (result) => result.recoveryCodes,
  );
}

/// Le message à montrer pour un code refusé. Le serveur écrit les siens en
/// français ; un 410 veut dire que l'étape a expiré et qu'il faut repartir du
/// mot de passe.
String otpErrorText(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['error'] != null) return data['error'].toString();
    if (error.response == null) return 'Serveur injoignable. Réessayez.';
  }
  return 'Vérification impossible. Réessayez.';
}

class _OtpCodeDialog<T> extends StatefulWidget {
  const _OtpCodeDialog({
    required this.title,
    required this.verify,
    required this.setup,
    required this.acceptsRecoveryCode,
    required this.recoveryCodesOf,
  });

  final String title;
  final Future<T> Function(String code) verify;
  final OtpSetup? setup;
  final bool acceptsRecoveryCode;
  final List<String> Function(T result)? recoveryCodesOf;

  @override
  State<_OtpCodeDialog<T>> createState() => _OtpCodeDialogState<T>();
}

class _OtpCodeDialogState<T> extends State<_OtpCodeDialog<T>> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  /// L'étape a expiré côté serveur : aucun code ne passera plus.
  bool _expired = false;

  /// Le résultat obtenu, gardé le temps de montrer les codes de secours.
  T? _result;
  List<String> _recoveryCodes = const [];

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Entrez le code affiché par votre application.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.verify(code);
      if (!mounted) return;
      final codes = widget.recoveryCodesOf?.call(result) ?? const <String>[];
      if (codes.isEmpty) {
        Navigator.of(context).pop(result);
        return;
      }
      setState(() {
        _busy = false;
        _result = result;
        _recoveryCodes = codes;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _expired = e is DioException && e.response?.statusCode == 410;
        _error = otpErrorText(e);
        _code.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final showingCodes = _recoveryCodes.isNotEmpty;
    return AlertDialog(
      backgroundColor: AppColors.surfaceElevated,
      title: Text(showingCodes ? 'Codes de secours' : widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: SingleChildScrollView(
          child: showingCodes
              ? RecoveryCodesView(codes: _recoveryCodes)
              : _codeStep(),
        ),
      ),
      actions: showingCodes
          ? [
              FilledButton(
                autofocus: true,
                onPressed: () => Navigator.of(context).pop(_result),
                child: const Text('J’ai noté mes codes'),
              ),
            ]
          : [
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(_expired ? 'Fermer' : 'Annuler'),
              ),
              if (!_expired)
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Valider'),
                ),
            ],
    );
  }

  Widget _codeStep() {
    final setup = widget.setup;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (setup != null) ...[
          const Text(
            'Scannez ce QR code avec une application d’authentification '
            '(Google Authenticator, Aegis, 1Password…), puis entrez le code '
            'qu’elle affiche.',
            style: TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          Center(child: _SecretQr(uri: setup.uri)),
          const SizedBox(height: 12),
          _SecretText(secret: setup.secret),
          const SizedBox(height: 16),
        ] else
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              widget.acceptsRecoveryCode
                  ? 'Entrez le code à six chiffres de votre application '
                      'd’authentification, ou l’un de vos codes de secours.'
                  : 'Entrez le code à six chiffres de votre application '
                      'd’authentification.',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ),
        TvDeferredKeyboard(
          builder: (context, focusNode, canRequestFocus) => TextField(
            controller: _code,
            focusNode: focusNode,
            canRequestFocus: canRequestFocus,
            autofocus: true,
            enabled: !_busy && !_expired,
            keyboardType: widget.acceptsRecoveryCode
                ? TextInputType.visiblePassword
                : TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: AppType.title1,
              fontWeight: FontWeight.w700,
              letterSpacing: 6,
            ),
            decoration: InputDecoration(
              hintText: '123456',
              errorText: _error,
              errorMaxLines: 3,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ),
      ],
    );
  }
}

class _SecretQr extends StatelessWidget {
  const _SecretQr({required this.uri});

  final String uri;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SizedBox.square(
        dimension: 180,
        child: QrImageView(
          data: uri,
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
}

/// Le secret en clair, pour qui configure l'application sur le téléphone même
/// qui affiche le QR code.
class _SecretText extends StatelessWidget {
  const _SecretText({required this.secret});

  final String secret;

  /// Groupé par quatre, comme les applications l'affichent.
  String get _grouped => [
        for (var i = 0; i < secret.length; i += 4)
          secret.substring(i, i + 4 > secret.length ? secret.length : i + 4),
      ].join(' ');

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SelectableText(
            _grouped,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
              color: AppColors.textSecondary,
              fontSize: AppType.subhead,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Copier la clé',
          icon: const Icon(AppIcons.copy, size: 18),
          onPressed: () => Clipboard.setData(ClipboardData(text: secret)),
        ),
      ],
    );
  }
}

/// La liste des codes de secours, avec de quoi la copier d'un coup.
class RecoveryCodesView extends StatelessWidget {
  const RecoveryCodesView({super.key, required this.codes});

  final List<String> codes;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Chacun de ces codes remplace une fois le code de votre application, '
          'si vous perdez votre téléphone. Gardez-les en lieu sûr : ils ne '
          'seront plus affichés.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 24,
            runSpacing: 8,
            children: [
              for (final code in codes)
                SelectableText(
                  code,
                  style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()],
                    fontSize: AppType.callout,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: codes.join('\n'))),
            icon: const Icon(AppIcons.copy, size: 18),
            label: const Text('Copier'),
          ),
        ),
      ],
    );
  }
}
