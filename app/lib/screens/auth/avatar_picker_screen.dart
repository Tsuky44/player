import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../models/profile_avatar.dart';
import '../../models/server_account.dart';
import '../../providers/auth_error_text.dart';
import '../../services/api_client.dart';
import '../../services/avatar_image.dart';
import '../../services/avatar_photo_cache.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_type.dart';
import '../../theme/profile_avatars.dart';
import '../../tv/tv_focus.dart';
import '../../tv/tv_mode.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/overlay_back_button.dart';
import '../../widgets/global/profile_disc.dart';
import '../../l10n/tr.dart';

/// Le choix de l'image de profil de [account] : un avatar de la galerie, une
/// photo, ou l'initiale. Enregistré sur son serveur, il suit le compte sur tous
/// ses appareils (ADR-0078).
///
/// Un choix part tout de suite : il n'y a pas de bouton « Enregistrer » à
/// chercher à la télécommande. Rend vrai quand l'image a changé.
class AvatarPickerScreen extends StatefulWidget {
  const AvatarPickerScreen({super.key, required this.account});

  final ServerAccount account;

  @override
  State<AvatarPickerScreen> createState() => _AvatarPickerScreenState();
}

class _AvatarPickerScreenState extends State<AvatarPickerScreen> {
  /// L'aperçu de ce qui est en train de partir.
  ProfileAvatar? _pending;
  bool _busy = false;

  ProfileAvatar get _current =>
      _pending ?? ProfileAvatar.parse(widget.account.avatar);

  Future<void> _save(
    ProfileAvatar preview,
    Future<User> Function(ApiClient api) send,
  ) async {
    if (_busy) return;
    final api = context.read<ApiClient>();
    setState(() {
      _busy = true;
      _pending = preview;
    });
    try {
      await send(api);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _pending = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_errorText(e)),
        backgroundColor: AppColors.error,
      ));
    }
  }

  Future<void> _choosePreset(AvatarPreset preset) => _save(
        PresetAvatar(preset.key),
        (api) => api.setAvatarPreset(widget.account, preset.key),
      );

  Future<void> _clear() => _save(
        const InitialAvatar(),
        (api) => api.setAvatarPreset(widget.account, null),
      );

  Future<void> _choosePhoto() async {
    if (_busy) return;
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(type: FileType.image);
    } catch (e) {
      debugPrint('AvatarPickerScreen: picker: $e');
      _snack(tr('Sélecteur de fichiers indisponible.'));
      return;
    }
    if (picked == null || !mounted) return;
    final file = picked;

    setState(() => _busy = true);
    try {
      final png = await squareAvatarPng(await file.readAsBytes());
      if (!mounted) return;
      setState(() => _busy = false);
      await _save(const InitialAvatar(), (api) async {
        final user = await api.uploadAvatarPhoto(widget.account, png);
        final shown = ProfileAvatar.parse(user.avatar);
        if (shown is PhotoAvatar) {
          AvatarPhotoCache.put(widget.account, shown.version, png);
        }
        return user;
      });
    } on FormatException {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(tr('Ce fichier n’est pas une image lisible.'));
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: AppColors.error,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final compact = AppLayout.isCompact(context);
    final onTv = TvScope.of(context);
    final current = _current;
    final selectedKey = current is PresetAvatar ? current.key : null;
    final tile = compact ? 64.0 : 84.0;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 56, 24, 40),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    children: [
                      AnimatedOpacity(
                        opacity: _busy ? 0.6 : 1,
                        duration: AppMotion.fade(context, AppMotion.micro),
                        curve: AppMotion.curve,
                        child: ProfileDisc(
                          account: widget.account,
                          avatar: _pending,
                          size: compact ? 104 : 128,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        tr('Choisir une image'),
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: AppType.title1,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        widget.account.username,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: AppType.body,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          // Une télévision n'a pas de photos à proposer.
                          if (!onTv)
                            FilledButton.tonalIcon(
                              onPressed: _busy ? null : _choosePhoto,
                              icon: const Icon(Icons.photo_outlined, size: 18),
                              label: Text(tr('Importer une photo')),
                            ),
                          if (current is! InitialAvatar)
                            TextButton(
                              onPressed: _busy ? null : _clear,
                              child: Text(tr('Revenir à l’initiale')),
                            ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: compact ? 12 : 16,
                        runSpacing: compact ? 12 : 16,
                        children: [
                          for (final (index, preset)
                              in ProfileAvatars.gallery.indexed)
                            _PresetTile(
                              preset: preset,
                              number: index + 1,
                              size: tile,
                              selected: preset.key == selectedKey,
                              autofocus: selectedKey == null
                                  ? index == 0
                                  : preset.key == selectedKey,
                              enabled: !_busy,
                              onSelect: () => _choosePreset(preset),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Positioned(top: 0, left: 0, child: OverlayBackButton()),
          ],
        ),
      ),
    );
  }
}

/// Le message d'un échec d'enregistrement. Un serveur d'avant les images de
/// profil ne connaît pas la route : autant le dire que d'afficher un 404.
String _errorText(Object error) {
  if (error is StateError) return error.message;
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status == 404 || status == 405) {
      return tr('Ce serveur doit être mis à jour pour enregistrer une image.');
    }
  }
  return authErrorText(error);
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.number,
    required this.size,
    required this.selected,
    required this.autofocus,
    required this.enabled,
    required this.onSelect,
  });

  final AvatarPreset preset;

  /// Sa place dans la galerie : ce que lit un lecteur d'écran, faute de mieux
  /// pour décrire un dessin.
  final int number;
  final double size;
  final bool selected;
  final bool autofocus;
  final bool enabled;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final radius = ProfileDisc.radiusFor(size);
    return Semantics(
      button: true,
      selected: selected,
      label: tr('Avatar {0}', [number]),
      onTap: enabled ? onSelect : null,
      excludeSemantics: true,
      child: TvFocusable(
        autofocus: autofocus,
        enabled: enabled,
        onSelect: onSelect,
        borderRadius: radius,
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onSelect : null,
            child: Container(
              width: size,
              height: size,
              foregroundDecoration: selected
                  ? BoxDecoration(
                      borderRadius: radius,
                      border:
                          Border.all(color: AppColors.textPrimary, width: 3),
                    )
                  : null,
              child: PresetArtwork(preset: preset, size: size),
            ),
          ),
        ),
      ),
    );
  }
}
