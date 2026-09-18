import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/player_layout_provider.dart';
import '../../../services/playback_preferences_storage.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/app_platform.dart';
import '../../player/display_frame_rate.dart';
import '../../player/hardware_decoding.dart';
import '../../player_studio/player_studio_screen.dart';
import '../../player_studio/widgets/player_layouts_sheet.dart';
import '../widgets/settings_ui.dart';

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
    final layouts = context.watch<PlayerLayoutProvider>();
    final options = PlaybackPreferencesStorage.audioLanguageOptions;
    final current = options
            .where((o) => o.code == _audioLang)
            .map((o) => o.label)
            .firstOrNull ??
        options.first.label;

    return SettingsPage(
      title: 'Lecture',
      description:
          'Comment les films et les séries se lisent sur cet appareil. Ces réglages ne changent rien sur vos autres appareils.',
      children: [
        SettingsGroup(
          title: 'Audio',
          children: [
            SettingsTile(
              icon: Icons.translate_rounded,
              iconColor: AppColors.primary,
              title: 'Langue audio par défaut',
              subtitle:
                  'Choisie à l’ouverture d’un média quand une piste correspondante existe.',
              showChevron: false,
              trailing: !_loaded
                  ? null
                  : PopupMenuButton<String?>(
                      tooltip: 'Langue audio par défaut',
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
                                Text(option.label),
                              ],
                            ),
                          ),
                      ],
                      child: _DropdownLabel(current),
                    ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Vidéo',
          children: [
            SettingsChoiceTile<HardwareDecodingPreference>(
              icon: Icons.memory_rounded,
              title: 'Décodage matériel',
              subtitle:
                  'Passez sur « Compatible » si l’image est noire ou verte alors que le son fonctionne.',
              footnote: 'Prend effet à la prochaine lecture.',
              value: HardwareDecoding.preference,
              options: const [
                (HardwareDecodingPreference.auto, 'Rapide'),
                (HardwareDecodingPreference.copy, 'Compatible'),
                (HardwareDecodingPreference.off, 'Logiciel'),
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
                title: 'Adapter l’écran au film',
                subtitle:
                    'Cale la fréquence du téléviseur sur celle du film pour supprimer les saccades. Désactivez-le si la lecture se fige au démarrage.',
                value: DisplayFrameRate.enabled,
                onChanged: (value) async {
                  await DisplayFrameRate.setEnabled(value);
                  if (mounted) setState(() {});
                },
              ),
          ],
        ),
        SettingsGroup(
          title: 'Séries',
          footer:
              'Un épisode enchaîne déjà sur le suivant au bout de 5 secondes. '
              'L’intro peut faire pareil.',
          children: [
            SettingsSwitchTile(
              icon: Icons.fast_forward_rounded,
              title: 'Passer l’intro automatiquement',
              subtitle:
                  'Quand le bouton « Passer l’intro » apparaît, l’intro est '
                  'sautée au bout de 5 secondes. Le moindre mouvement de '
                  'souris ou appui sur une touche annule le saut.',
              value: PlaybackPreferencesStorage.autoSkipIntro,
              onChanged: (value) async {
                await PlaybackPreferencesStorage.setAutoSkipIntro(value);
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
        SettingsGroup(
          title: 'Interface du lecteur',
          footer:
              'Vos playeurs sont liés à votre compte et vous suivent sur tous vos appareils.',
          children: [
            SettingsTile(
              icon: Icons.widgets_outlined,
              title: 'Mes playeurs',
              subtitle: 'Actif : ${layouts.activePresetName}',
              onTap: () => showPlayerLayoutsSheet(context),
            ),
            SettingsTile(
              icon: Icons.dashboard_customize_outlined,
              title: 'Player Studio',
              subtitle: 'Composer et placer les contrôles du lecteur',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PlayerStudioScreen()),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DropdownLabel extends StatelessWidget {
  const _DropdownLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
          const Icon(Icons.unfold_more_rounded,
              size: 18, color: AppColors.textSecondary),
        ],
      ),
    );
  }
}
