import 'package:flutter/material.dart';

import '../../../services/playback_preferences_storage.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/app_platform.dart';
import '../../player/display_frame_rate.dart';
import '../../player/hardware_decoding.dart';
import '../widgets/settings_dropdown_label.dart';
import '../widgets/settings_ui.dart';
import 'playback_still_watching_group.dart';
import '../../../l10n/tr.dart';

class PlaybackPage extends StatefulWidget {
  const PlaybackPage({super.key});

  @override
  State<PlaybackPage> createState() => _PlaybackPageState();
}

class _PlaybackPageState extends State<PlaybackPage> {
  final _storage = PlaybackPreferencesStorage();
  String? _audioLang;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _reload();
    // Un réglage changé depuis un autre appareil peut arriver pendant que la
    // page est ouverte : elle l'affiche, et demande au compte où il en est.
    PlaybackPreferencesStorage.accountRevision.addListener(_reload);
    PlaybackPreferencesStorage.syncWithAccount();
  }

  @override
  void dispose() {
    PlaybackPreferencesStorage.accountRevision.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    _storage.loadDefaultAudioLang().then((lang) {
      if (mounted) {
        setState(() {
          _audioLang = lang;
          _loaded = true;
        });
      }
    });
  }

  Future<void> _setAudioLang(String? lang) async {
    await _storage.saveDefaultAudioLang(lang);
    if (mounted) setState(() => _audioLang = lang);
  }

  @override
  Widget build(BuildContext context) {
    final options = PlaybackPreferencesStorage.audioLanguageOptions;
    final current = options
            .where((o) => o.code == _audioLang)
            .map((o) => tr(o.label))
            .firstOrNull ??
        tr(options.first.label);

    return SettingsPage(
      title: tr('Lecture'),
      description:
          tr('Comment les films et les séries se lisent. Vos préférences '
              'suivent votre compte sur tous vos appareils ; seuls les '
              'réglages vidéo restent propres à celui-ci.'),
      children: [
        SettingsGroup(
          title: tr('Audio'),
          children: [
            SettingsTile(
              icon: Icons.translate_rounded,
              iconColor: AppColors.primary,
              title: tr('Langue audio par défaut'),
              subtitle:
                  tr('Choisie à l’ouverture d’un média quand une piste '
                      'correspondante existe.'),
              showChevron: false,
              trailing: !_loaded
                  ? null
                  : PopupMenuButton<String?>(
                      tooltip: tr('Langue audio par défaut'),
                      color: AppColors.surfaceElevated,
                      initialValue: _audioLang,
                      onSelected: _setAudioLang,
                      itemBuilder: (_) => [
                        for (final option in options)
                          PopupMenuItem<String?>(
                            value: option.code,
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 22,
                                  child: option.code == _audioLang
                                      ? const Icon(Icons.check_rounded,
                                          size: 18, color: AppColors.primary)
                                      : null,
                                ),
                                const SizedBox(width: 6),
                                Text(tr(option.label)),
                              ],
                            ),
                          ),
                      ],
                      child: SettingsDropdownLabel(current),
                    ),
            ),
          ],
        ),
        // AetherEngine, sur les appareils Apple, choisit seul entre décodeur
        // matériel et FFmpeg : le groupe n'aurait rien à y proposer.
        if (!AppPlatform.isApple)
          SettingsGroup(
            title: tr('Vidéo'),
            // Ils corrigent le matériel de cet appareil : les envoyer sur un
            // autre y casserait une lecture qui marchait (ADR-0004).
            footer: tr('Propres à cet appareil : ils dépendent de son matériel.'),
            children: [
              SettingsChoiceTile<HardwareDecodingPreference>(
                icon: Icons.memory_rounded,
                title: tr('Décodage matériel'),
                subtitle:
                    tr('Passez sur « Compatible » si l’image est noire ou '
                        'verte alors que le son fonctionne.'),
                footnote: tr('Prend effet à la prochaine lecture.'),
                value: HardwareDecoding.preference,
                options: [
                  (HardwareDecodingPreference.auto, tr('Rapide')),
                  (HardwareDecodingPreference.copy, tr('Compatible')),
                  (HardwareDecodingPreference.off, tr('Logiciel')),
                ],
                onChanged: (value) async {
                  await HardwareDecoding.setPreference(value);
                  if (mounted) setState(() {});
                },
              ),
              // Android seul laisse une app choisir le mode d'affichage.
              if (AppPlatform.isAndroid)
                SettingsSwitchTile(
                  icon: Icons.slow_motion_video_rounded,
                  title: tr('Adapter l’écran au film'),
                  subtitle:
                      tr('Cale la fréquence du téléviseur sur celle du film '
                          'pour supprimer les saccades. Désactivez-le si la '
                          'lecture se fige au démarrage.'),
                  value: DisplayFrameRate.enabled,
                  onChanged: (value) async {
                    await DisplayFrameRate.setEnabled(value);
                    if (mounted) setState(() {});
                  },
                ),
            ],
          ),
        SettingsGroup(
          title: tr('Séries'),
          footer:
              tr('Un épisode enchaîne déjà sur le suivant au bout de 5 '
                  'secondes. L’intro peut faire pareil.'),
          children: [
            SettingsSwitchTile(
              icon: Icons.fast_forward_rounded,
              title: tr('Passer l’intro automatiquement'),
              subtitle:
                  tr('Quand le bouton « Passer l’intro » apparaît, l’intro '
                      'est sautée au bout de 5 secondes. Le moindre '
                      'mouvement de souris ou appui sur une touche annule le '
                      'saut.'),
              value: PlaybackPreferencesStorage.autoSkipIntro,
              onChanged: (value) async {
                await PlaybackPreferencesStorage.setAutoSkipIntro(value);
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
        StillWatchingSettingsGroup(
          value: PlaybackPreferencesStorage.stillWatching,
          onChanged: (value) async {
            await PlaybackPreferencesStorage.setStillWatching(value);
            if (mounted) setState(() {});
          },
        ),
      ],
    );
  }
}
