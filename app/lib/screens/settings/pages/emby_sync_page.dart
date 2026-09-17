import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../../../tv/tv_deferred_keyboard.dart';
import '../widgets/settings_ui.dart';

/// Lie le compte à un compte Emby pour que la progression (où l'on en est,
/// vu / pas vu) suive dans les deux sens. C'est le serveur qui synchronise :
/// l'app n'a pas besoin d'être ouverte.
class EmbySyncPage extends StatefulWidget {
  const EmbySyncPage({super.key});

  @override
  State<EmbySyncPage> createState() => _EmbySyncPageState();
}

class _EmbySyncPageState extends State<EmbySyncPage> {
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();

  EmbyLinkStatus? _status;
  String? _error;
  bool _busy = false;
  bool _syncing = false;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _apply(EmbyLinkStatus status) {
    _status = status;
    if (status.linked) {
      _url.text = status.url;
      _username.text = status.username;
    }
    _password.clear();
  }

  Future<void> _load() async {
    try {
      final status = await context.read<ApiClient>().getEmbyLink();
      if (!mounted) return;
      setState(() {
        _apply(status);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          settingsErrorText(e, 'Impossible de charger le lien Emby.'));
    }
  }

  Future<void> _link() async {
    if (_url.text.trim().isEmpty || _username.text.trim().isEmpty) {
      showSettingsSnack(context, 'Renseignez l’adresse et le nom d’utilisateur.',
          error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final status = await context.read<ApiClient>().linkEmby(
            url: _url.text.trim(),
            username: _username.text.trim(),
            password: _password.text,
          );
      if (!mounted) return;
      setState(() => _apply(status));
      showSettingsSnack(context,
          'Compte Emby lié. La première synchronisation démarre.');
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, 'Connexion à Emby impossible.'),
            error: true);
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _sync() async {
    setState(() => _syncing = true);
    final api = context.read<ApiClient>();
    try {
      final result = await api.syncEmbyNow();
      if (!mounted) return;
      showSettingsSnack(
          context,
          result.pulled == 0 && result.pushed == 0
              ? 'Déjà à jour.'
              : '${result.pulled} reçue(s) d’Emby, ${result.pushed} envoyée(s) à Emby.');
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, 'Échec de la synchronisation.'),
            error: true);
      }
    }
    if (!mounted) return;
    setState(() => _syncing = false);
    await _load();
  }

  Future<void> _unlink() async {
    final confirmed = await confirmSettingsAction(
      context,
      title: 'Délier le compte Emby ?',
      message:
          'La progression cesse d’être synchronisée. Rien n’est effacé, ni ici ni sur Emby.',
      confirmLabel: 'Délier',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final status = await context.read<ApiClient>().unlinkEmby();
      if (!mounted) return;
      setState(() {
        _apply(status);
        _url.clear();
        _username.clear();
      });
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, 'Impossible de délier le compte.'),
            error: true);
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hint,
    TextInputType? keyboardType,
    bool password = false,
  }) {
    return TvDeferredKeyboard(
      builder: (context, focusNode, canRequestFocus) => TextField(
        focusNode: focusNode,
        canRequestFocus: canRequestFocus,
        controller: controller,
        keyboardType: keyboardType,
        obscureText: password && _obscure,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon),
          suffixIcon: password
              ? IconButton(
                  tooltip: _obscure ? 'Afficher' : 'Masquer',
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(_obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                )
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final linked = status?.linked ?? false;

    return SettingsPage(
      title: 'Synchro Emby',
      description:
          'Reprenez vos films et vos séries là où vous les avez laissés, que vous les regardiez ici ou sur Emby. Les médias sont reconnus par leur fiche TMDB.',
      onRefresh: _load,
      children: [
        if (_error != null) SettingsBanner(_error!, tone: BannerTone.error),
        if (status == null && _error == null) const SettingsLoading(),
        if (status != null && linked && status.lastError.isNotEmpty)
          SettingsBanner(status.lastError, tone: BannerTone.error),
        if (status != null && linked)
          SettingsGroup(
            title: 'Compte lié',
            trailing: SettingsPill(
              status.lastError.isEmpty ? 'Actif' : 'En erreur',
              color: status.lastError.isEmpty
                  ? AppColors.success
                  : AppColors.error,
              icon: status.lastError.isEmpty
                  ? Icons.check_rounded
                  : Icons.error_outline_rounded,
            ),
            footer:
                'Ce qui change ici part vers Emby dans la minute ; Emby est relu toutes les 10 minutes. Quand les deux diffèrent, la lecture la plus récente l’emporte.',
            children: [
              SettingsTile(
                icon: Icons.person_rounded,
                iconColor: AppColors.primary,
                title: status.username,
                subtitle: status.url,
                showChevron: false,
              ),
              SettingsTile(
                icon: Icons.sync_rounded,
                title: 'Synchroniser maintenant',
                subtitle: _syncing
                    ? 'Synchronisation en cours…'
                    : status.lastSyncAt == null
                        ? 'Pas encore synchronisé'
                        : 'Dernière synchronisation ${relativeTime(status.lastSyncAt!)}',
                trailing: _syncing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: _syncing || _busy ? null : _sync,
              ),
              SettingsTile(
                icon: Icons.link_off_rounded,
                title: 'Délier le compte Emby',
                destructive: true,
                onTap: _syncing || _busy ? null : _unlink,
              ),
            ],
          ),
        if (status != null)
          SettingsGroup(
            title: linked ? 'Reconnecter' : 'Connexion à Emby',
            footer: linked
                ? 'À faire si le mot de passe Emby a changé ou si la session a été révoquée.'
                : 'Le mot de passe sert uniquement à ouvrir une session sur Emby : il n’est pas enregistré.',
            padded: true,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _field(
                    controller: _url,
                    label: 'Adresse du serveur Emby',
                    hint: 'http://192.168.1.10:8096',
                    icon: Icons.link_rounded,
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 12),
                  _field(
                    controller: _username,
                    label: 'Nom d’utilisateur Emby',
                    icon: Icons.person_outline_rounded,
                  ),
                  const SizedBox(height: 12),
                  _field(
                    controller: _password,
                    label: 'Mot de passe Emby',
                    icon: Icons.key_rounded,
                    password: true,
                  ),
                  const SizedBox(height: 14),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: _busy ? null : _link,
                      child: Text(_busy
                          ? 'Connexion…'
                          : linked
                              ? 'Reconnecter'
                              : 'Lier le compte'),
                    ),
                  ),
                ],
              ),
            ],
          ),
      ],
    );
  }
}
