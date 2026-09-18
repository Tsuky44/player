import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart';
import '../../../services/api_client.dart';
import '../../../services/client_log.dart';
import '../../../theme/app_colors.dart';
import '../settings_screen.dart';
import '../widgets/settings_ui.dart';

/// Ce que l'app a écrit sur elle-même, lisible sans câble.
///
/// La page ne fabrique rien : elle montre le tampon de [ClientLog], que
/// l'application remplit de toute façon. Son intérêt tient au bouton « Copier »
/// — une panne qu'on peut coller dans un message est une panne qu'on peut
/// corriger, là où « ça ne se lance pas » n'a jamais rien appris à personne.
///
/// Le réglage serveur des journaux de lecture tient ici aussi, et pas dans la
/// page des clés d'API où il avait atterri : ce qui décide si les journaux
/// existent appartient à la page où on vient les lire. Il n'apparaît qu'aux
/// comptes qui peuvent le changer.
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  bool _errorsOnly = false;

  /// Le réglage serveur, chargé seulement si ce compte peut le lire — la route
  /// `/api/settings` exige `manage_settings`, et une page qui la demande sans
  /// le droit ne ferait qu'afficher un 403 à qui n'a rien demandé.
  ServerSettings? _server;
  bool _serverLogsEnabled = true;
  bool _serverStatsEnabled = true;
  bool _savingServerLogs = false;
  bool _savingServerStats = false;
  String? _serverError;

  bool get _canManageServer =>
      context.read<AuthProvider>().permissions.manageSettings;

  bool get _canReadHistory =>
      context.read<AuthProvider>().permissions.manageUsers;

  @override
  void initState() {
    super.initState();
    if (_canManageServer) _loadServer();
  }

  Future<void> _loadServer() async {
    try {
      final settings = await context.read<ApiClient>().getServerSettings();
      if (!mounted) return;
      setState(() {
        _server = settings;
        _serverLogsEnabled = settings.playbackLogsEnabled;
        _serverStatsEnabled = settings.playbackStatsEnabled;
        _serverError = null;
      });
    } catch (e) {
      if (!mounted) return;
      // Un serveur plus ancien n'a pas ce réglage. La section le dit et
      // s'efface : le journal local, lui, marche de toute façon.
      setState(() => _serverError = settingsErrorText(
          e, 'Réglage indisponible sur ce serveur.'));
    }
  }

  Future<void> _saveServerLogs(bool value) async {
    setState(() {
      _serverLogsEnabled = value;
      _savingServerLogs = true;
    });
    try {
      final updated = await context
          .read<ApiClient>()
          .updateServerSettings(playbackLogsEnabled: value);
      if (!mounted) return;
      setState(() {
        _server = updated;
        _serverLogsEnabled = updated.playbackLogsEnabled;
      });
      showSettingsSnack(
        context,
        value
            ? 'Journaux des lectures activés.'
            : 'Journaux des lectures désactivés.',
      );
    } catch (e) {
      if (!mounted) return;
      // Remettre l'interrupteur là où le serveur l'a laissé : un interrupteur
      // qui reste sur une position que le serveur a refusée ment.
      setState(() => _serverLogsEnabled = _server?.playbackLogsEnabled ?? true);
      showSettingsSnack(
          context, settingsErrorText(e, "Échec de l'enregistrement."),
          error: true);
    }
    if (mounted) setState(() => _savingServerLogs = false);
  }

  Future<void> _saveServerStats(bool value) async {
    setState(() {
      _serverStatsEnabled = value;
      _savingServerStats = true;
    });
    try {
      final updated = await context
          .read<ApiClient>()
          .updateServerSettings(playbackStatsEnabled: value);
      if (!mounted) return;
      setState(() {
        _server = updated;
        _serverStatsEnabled = updated.playbackStatsEnabled;
      });
      showSettingsSnack(
        context,
        value ? 'Mesures des lectures activées.' : 'Mesures désactivées.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(
          () => _serverStatsEnabled = _server?.playbackStatsEnabled ?? true);
      showSettingsSnack(
          context, settingsErrorText(e, "Échec de l'enregistrement."),
          error: true);
    }
    if (mounted) setState(() => _savingServerStats = false);
  }

  Future<void> _copy(List<LogEntry> shown) async {
    await Clipboard.setData(
      ClipboardData(text: ClientLog.export(errorsOnly: _errorsOnly)),
    );
    if (!mounted) return;
    showSettingsSnack(
      context,
      '${shown.length} ligne${shown.length > 1 ? 's' : ''} copiée'
      '${shown.length > 1 ? 's' : ''}.',
    );
  }

  Future<void> _clear() async {
    final confirmed = await confirmSettingsAction(
      context,
      title: 'Vider le journal ?',
      message:
          'Les lignes déjà enregistrées sont perdues. L’app continue d’en écrire de nouvelles.',
      confirmLabel: 'Vider',
    );
    if (!confirmed || !mounted) return;
    ClientLog.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Le journal s'écrit pendant qu'on le regarde : une lecture lancée depuis
    // un autre onglet, une requête qui échoue en arrière-plan. La page suit.
    return ValueListenableBuilder<int>(
      valueListenable: ClientLog.revision,
      builder: (context, _, __) {
        final all = ClientLog.entries;
        final errors =
            all.where((e) => e.level == LogLevel.error).toList(growable: false);
        final shown = _errorsOnly ? errors : all;
        final layout = SettingsLayout.maybeOf(context);

        return SettingsPage(
          title: 'Journal',
          description:
              'Ce que cette application enregistre sur elle-même : démarrages de lecture, '
              'réponses du serveur, pannes. Rien n’en sort tant que vous ne copiez pas — '
              'le journal vit en mémoire et disparaît à la fermeture de l’app. '
              'Les journaux que les lectures laissent sur le serveur, eux, se relisent '
              'depuis n’importe quel appareil.',
          actions: [
            FilledButton.icon(
              onPressed: shown.isEmpty ? null : () => _copy(shown),
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copier'),
            ),
            OutlinedButton.icon(
              onPressed: all.isEmpty ? null : _clear,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Vider'),
            ),
          ],
          children: [
            if (_canManageServer) ...[
              SettingsGroup(
                title: 'Journaux des lectures (serveur)',
                footer:
                    'Chaque lecture envoie son journal et ses mesures en se terminant, '
                    'et le serveur garde ceux des dix dernières. On les relit depuis '
                    'l’Historique, en ouvrant une lecture — y compris celle d’un autre '
                    'appareil, ce que le journal ci-dessous ne permet pas. Les mesures '
                    'ont leur propre interrupteur : elles interrogent le lecteur toutes '
                    'les cinq secondes, là où le journal ne coûte rien avant la fin.',
                children: [
                  if (_serverError != null)
                    SettingsEmptyNote(_serverError!,
                        icon: Icons.cloud_off_rounded)
                  else ...[
                    SettingsSwitchTile(
                      icon: Icons.cloud_sync_rounded,
                      title: 'Conserver les journaux des lectures',
                      subtitle: _server == null
                          ? 'Chargement…'
                          : _serverLogsEnabled
                              ? 'Les dix dernières lectures gardent leur journal.'
                              : 'Aucun journal de lecture n’est conservé.',
                      value: _serverLogsEnabled,
                      onChanged: _server == null || _savingServerLogs
                          ? null
                          : _saveServerLogs,
                    ),
                    SettingsSwitchTile(
                      icon: Icons.speed_rounded,
                      title: 'Mesurer la lecture',
                      subtitle: _server == null
                          ? 'Chargement…'
                          : _serverStatsEnabled
                              ? 'Cadence, débit, décodeur et images perdues, '
                                  'relevés pendant la lecture.'
                              : 'Aucune mesure n’est relevée.',
                      value: _serverStatsEnabled,
                      onChanged: _server == null || _savingServerStats
                          ? null
                          : _saveServerStats,
                    ),
                    if (_canReadHistory && layout != null)
                      SettingsTile(
                        icon: Icons.history_rounded,
                        title: 'Ouvrir l’Historique',
                        subtitle:
                            'Chaque lecture y ouvre son journal, erreurs comprises.',
                        onTap: () =>
                            layout.openSection(SettingsSections.activity),
                      ),
                  ],
                ],
              ),
              const SizedBox(height: 16),
            ],
            SettingsGroup(
              title: 'Journal de cette application',
              children: [
                SettingsSwitchTile(
                  icon: Icons.filter_alt_rounded,
                  title: 'Erreurs seulement',
                  subtitle: errors.isEmpty
                      ? 'Aucune erreur enregistrée depuis le démarrage de l’app.'
                      : '${errors.length} erreur${errors.length > 1 ? 's' : ''} '
                          'sur ${all.length} ligne${all.length > 1 ? 's' : ''}.',
                  value: _errorsOnly,
                  onChanged: (value) => setState(() => _errorsOnly = value),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (shown.isEmpty)
              SettingsEmptyNote(
                _errorsOnly
                    ? 'Aucune erreur. Si quelque chose vient de mal se passer, '
                        'coupez ce filtre : la cause est souvent dans les lignes ordinaires.'
                    : 'Rien pour l’instant. Reproduisez le problème, puis revenez ici.',
                icon: Icons.receipt_long_rounded,
              )
            else
              // Les plus récentes en haut : ce qu'on cherche vient de se
              // produire, et faire défiler six cents lignes pour l'atteindre
              // serait une drôle de façon de le présenter.
              SettingsGroup(
                title: 'Les plus récentes d’abord',
                padded: true,
                children: [
                  for (final entry in shown.reversed) _LogLine(entry: entry),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// Une ligne, sélectionnable.
///
/// `SelectableText` plutôt que `Text` : sur un ordinateur, copier la seule
/// ligne qui compte vaut mieux que copier les six cents.
class _LogLine extends StatelessWidget {
  const _LogLine({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final isError = entry.level == LogLevel.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Un filet plutôt qu'une pastille : il tient sur toute la hauteur
          // d'une ligne qui se replie sur quatre, là où une icône n'aurait
          // marqué que la première.
          Container(
            width: 3,
            constraints: const BoxConstraints(minHeight: 18),
            margin: const EdgeInsets.only(top: 2, right: 10),
            decoration: BoxDecoration(
              color: isError ? AppColors.error : AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: SelectableText(
              entry.format(),
              style: TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Menlo', 'Consolas', 'Roboto Mono'],
                fontSize: 12,
                height: 1.4,
                color: isError ? AppColors.error : AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
