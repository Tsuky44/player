import 'package:flutter/material.dart';

import '../../services/playback_preferences_storage.dart';
import '../../theme/app_colors.dart';

class PlaybackPreferencesScreen extends StatefulWidget {
  const PlaybackPreferencesScreen({super.key});

  @override
  State<PlaybackPreferencesScreen> createState() =>
      _PlaybackPreferencesScreenState();
}

class _PlaybackPreferencesScreenState extends State<PlaybackPreferencesScreen> {
  final _storage = PlaybackPreferencesStorage();
  String? _defaultAudioLang;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lang = await _storage.loadDefaultAudioLang();
    if (!mounted) return;
    setState(() {
      _defaultAudioLang = lang;
      _loading = false;
    });
  }

  Future<void> _selectAudioLang(String? lang) async {
    await _storage.saveDefaultAudioLang(lang);
    if (!mounted) return;
    setState(() => _defaultAudioLang = lang);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        title: const Text('Lecture'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Langue audio par défaut',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Appliquée à chaque nouveau média si une piste correspondante existe.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.65),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 16),
                ...PlaybackPreferencesStorage.audioLanguageOptions.map((opt) {
                  final selected = _defaultAudioLang == opt.code ||
                      (_defaultAudioLang == null && opt.code == null);
                  return Card(
                    color: AppColors.surfaceElevated,
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text(
                        opt.label,
                        style: TextStyle(
                          color: selected ? AppColors.primary : Colors.white,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                      trailing: selected
                          ? const Icon(Icons.check_rounded,
                              color: AppColors.primary)
                          : null,
                      onTap: () => _selectAudioLang(opt.code),
                    ),
                  );
                }),
              ],
            ),
    );
  }
}
