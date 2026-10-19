import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/tr.dart';
import '../../../models/announcement.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../../../tv/tv_deferred_keyboard.dart';
import '../../../widgets/global/announcement_dialog.dart';
import '../widgets/settings_ui.dart';

/// Écrire le message que chaque compte verra en grand à sa prochaine
/// ouverture de l'app (ADR-0069). Réservé à manage_settings.
class AnnouncementPage extends StatefulWidget {
  const AnnouncementPage({super.key});

  /// Les bornes du serveur (`handlers/announcements.go`).
  static const maxTitleLength = 120;
  static const maxMessageLength = 4000;

  @override
  State<AnnouncementPage> createState() => _AnnouncementPageState();
}

class _AnnouncementPageState extends State<AnnouncementPage> {
  final _title = TextEditingController();
  final _message = TextEditingController();

  ServerAnnouncement? _current;
  bool _loaded = false;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _message.addListener(_onMessageChanged);
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _message.dispose();
    super.dispose();
  }

  bool _hadMessage = false;

  /// « Publier » ne s'allume qu'avec un message : seul le passage du vide au
  /// non-vide redessine la page, pas chaque lettre.
  void _onMessageChanged() {
    final has = _message.text.trim().isNotEmpty;
    if (has != _hadMessage) setState(() => _hadMessage = has);
  }

  void _apply(ServerAnnouncement? current) {
    _current = current;
    _title.text = current?.title ?? '';
    _message.text = current?.message ?? '';
  }

  Future<void> _load() async {
    try {
      final current = await context.read<ApiClient>().getCurrentAnnouncement();
      if (!mounted) return;
      setState(() {
        _apply(current);
        _loaded = true;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          settingsErrorText(e, tr('Impossible de charger le message.')));
    }
  }

  Future<void> _publish() async {
    final confirmed = await confirmSettingsAction(
      context,
      title: tr('Publier le message ?'),
      message: tr('Chaque compte le verra en grand à sa prochaine ouverture '
          'de l’app, même ceux qui avaient fermé le précédent.'),
      confirmLabel: tr('Publier'),
      destructive: false,
    );
    if (!confirmed || !mounted) return;
    await _run(
      () => context.read<ApiClient>().publishAnnouncement(
            title: _title.text.trim(),
            message: _message.text.trim(),
          ),
      done: tr('Message publié.'),
    );
  }

  Future<void> _clear() async {
    final confirmed = await confirmSettingsAction(
      context,
      title: tr('Retirer le message ?'),
      message: tr('Ceux qui ne l’ont pas encore vu ne le verront pas.'),
      confirmLabel: tr('Retirer'),
    );
    if (!confirmed || !mounted) return;
    await _run(() async {
      await context.read<ApiClient>().clearAnnouncement();
      return null;
    }, done: tr('Message retiré.'));
  }

  Future<void> _run(
    Future<ServerAnnouncement?> Function() action, {
    required String done,
  }) async {
    setState(() => _busy = true);
    try {
      final updated = await action();
      if (!mounted) return;
      setState(() => _apply(updated));
      showSettingsSnack(context, done);
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, tr('Échec de l’enregistrement.')),
            error: true);
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  void _preview() {
    showAnnouncementDialog(
      context,
      ServerAnnouncement(
        id: 0,
        title: _title.text.trim(),
        message: _message.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;

    return SettingsPage(
      title: tr('Message aux utilisateurs'),
      description: tr('Un message affiché en grand à chaque compte, une seule '
          'fois, la prochaine fois qu’il ouvre l’app : une maintenance, une '
          'nouveauté, un changement à connaître.'),
      children: [
        if (_error != null) SettingsBanner(_error!, tone: BannerTone.error),
        if (!_loaded && _error == null) const SettingsLoading(),
        if (_loaded) ...[
          if (current != null)
            SettingsBanner(
              current.createdAt == null
                  ? tr('Un message est en ligne.')
                  : tr('Message en ligne, publié {0}.',
                      [relativeTime(current.createdAt!.toLocal())]),
              tone: BannerTone.success,
            ),
          SettingsGroup(
            title: tr('Message'),
            footer: tr('Publier remplace le message en cours. Vous ne le '
                'verrez pas vous-même : vous venez de l’écrire.'),
            padded: true,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TvDeferredKeyboard(
                    builder: (context, focusNode, canRequestFocus) => TextField(
                      focusNode: focusNode,
                      canRequestFocus: canRequestFocus,
                      controller: _title,
                      maxLength: AnnouncementPage.maxTitleLength,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        labelText: tr('Titre (facultatif)'),
                        hintText: tr('Un message de votre serveur'),
                        prefixIcon: const Icon(Icons.title_rounded),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TvDeferredKeyboard(
                    builder: (context, focusNode, canRequestFocus) => TextField(
                      focusNode: focusNode,
                      canRequestFocus: canRequestFocus,
                      controller: _message,
                      minLines: 4,
                      maxLines: 10,
                      maxLength: AnnouncementPage.maxMessageLength,
                      keyboardType: TextInputType.multiline,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        labelText: tr('Message'),
                        hintText: tr('Ce que vous voulez dire à tout le monde'),
                        alignLabelWithHint: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (current != null)
                        TextButton(
                          onPressed: _busy ? null : _clear,
                          style: TextButton.styleFrom(
                              foregroundColor: AppColors.error),
                          child: Text(tr('Retirer le message')),
                        ),
                      OutlinedButton(
                        onPressed: _busy || !_hadMessage ? null : _preview,
                        child: Text(tr('Aperçu')),
                      ),
                      FilledButton(
                        onPressed: _busy || !_hadMessage ? null : _publish,
                        child: Text(_busy ? tr('Enregistrement…') : tr('Publier')),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ],
    );
  }
}
