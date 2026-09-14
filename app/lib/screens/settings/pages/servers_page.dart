import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../../../tv/tv_deferred_keyboard.dart';
import '../servers_screen.dart';
import '../widgets/settings_ui.dart';

class ServersPage extends StatefulWidget {
  const ServersPage({super.key});

  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage> {
  final _urlController = TextEditingController();
  bool _editing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _urlController.text = context.read<ApiClient>().baseUrl;
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  /// Le même serveur se joint parfois autrement — l'IP locale hier, un nom de
  /// domaine aujourd'hui. Déplacer le compte plutôt que repointer le client
  /// garde sa session : c'est le serveur qui la connaît, pas l'adresse.
  /// Voir ADR-0013.
  Future<void> _saveUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    final api = context.read<ApiClient>();
    setState(() => _saving = true);
    try {
      await api.updateActiveServerUrl(url);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _editing = false;
        _urlController.text = api.baseUrl;
      });
      showSettingsSnack(context, 'Adresse du serveur enregistrée.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSettingsSnack(context, 'Échec de l’enregistrement de l’adresse.',
          error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final active = auth.activeServer;

    return SettingsPage(
      title: 'Serveurs',
      description:
          'Les serveurs Onyx de cet appareil. Liez vos comptes, même sous des noms différents : la progression vous suit d’un serveur à l’autre.',
      children: [
        SettingsGroup(
          title: 'Serveur actif',
          children: [
            SettingsTile(
              icon: Icons.dns_rounded,
              iconColor: AppColors.success,
              title: active?.displayName ?? 'Aucun serveur',
              subtitle: active == null
                  ? null
                  : '${active.username} · ${context.read<ApiClient>().baseUrl}',
              showChevron: false,
              trailing: TextButton(
                onPressed: () => setState(() => _editing = !_editing),
                child: Text(_editing ? 'Annuler' : 'Modifier l’adresse'),
              ),
            ),
            if (_editing)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Utile quand le serveur change d’adresse (IP locale, nom de domaine) : votre session est conservée.',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 12.5),
                    ),
                    const SizedBox(height: 12),
                    TvDeferredKeyboard(
                      builder: (context, focusNode, canRequestFocus) =>
                          TextField(
                        focusNode: focusNode,
                        canRequestFocus: canRequestFocus,
                        controller: _urlController,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _saveUrl(),
                        decoration: const InputDecoration(
                          labelText: 'Adresse du serveur',
                          hintText: 'http://192.168.1.10:8080',
                          prefixIcon: Icon(Icons.link_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: _saving ? null : _saveUrl,
                        child:
                            Text(_saving ? 'Enregistrement…' : 'Enregistrer'),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SettingsGroup(
          title: 'Mes serveurs',
          padded: true,
          children: [ServersScreen(embedded: true)],
        ),
      ],
    );
  }
}
