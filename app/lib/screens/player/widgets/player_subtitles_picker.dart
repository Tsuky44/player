import 'package:flutter/material.dart';
import '../playback/playback_session.dart';

import '../../../models/models.dart';
import '../hooks/use_player_controller.dart';
import 'player_settings_ui.dart';

/// Subtitle track list shared by the settings sheet and the subtitles popup.
class PlayerSubtitlesPicker extends StatefulWidget {
  final PlaybackSession session;
  final PlayerController playerController;
  final VoidCallback onSelected;

  const PlayerSubtitlesPicker({
    super.key,
    required this.session,
    required this.playerController,
    required this.onSelected,
  });

  @override
  State<PlayerSubtitlesPicker> createState() => _PlayerSubtitlesPickerState();
}

class _PlayerSubtitlesPickerState extends State<PlayerSubtitlesPicker> {
  bool _isExtractingSubtitles = false;

  PlayerController get _controller => widget.playerController;

  String _subtitleTrackName(PlaybackTrack track, int index) {
    if (track.id == 'no') return 'Désactivés';
    return track.title ??
        (track.language != null
            ? 'Sous-titre (${track.language})'
            : 'Sous-titre ${index + 1}');
  }

  @override
  Widget build(BuildContext context) {
    final mediaTracks = _controller.mediaTracks;
    if (mediaTracks == null) {
      return const _EmptySubtitlesMessage();
    }

    final useInternal = _controller.currentQuality == null;

    return Column(
      children: [
        Expanded(
          child: useInternal
              ? _buildInternalSubtitleList()
              : _buildCanonicalSubtitleList(mediaTracks.subtitles),
        ),
        if (mediaTracks.subtitles.any((s) => !s.ready))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: (_isExtractingSubtitles || _controller.isExtractingSubtitles)
                    ? null
                    : () => _forceExtractSubtitles(),
                icon: (_isExtractingSubtitles || _controller.isExtractingSubtitles)
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined, size: 16),
                label: Text(
                  (_isExtractingSubtitles || _controller.isExtractingSubtitles)
                      ? 'Extraction en cours…'
                      : 'Extraire les sous-titres',
                  style: const TextStyle(fontSize: 12, fontFamily: 'Manrope'),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF0A84FF),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _forceExtractSubtitles() async {
    setState(() => _isExtractingSubtitles = true);
    try {
      final subs = await _controller.forceExtractSubtitles();
      if (!mounted) return;
      setState(() => _isExtractingSubtitles = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            subs.isEmpty
                ? 'Aucun sous-titre texte trouvé dans ce fichier'
                : '${subs.length} piste${subs.length > 1 ? 's' : ''} extraite${subs.length > 1 ? 's' : ''}',
          ),
          backgroundColor: subs.isEmpty ? Colors.orange.shade800 : Colors.green.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isExtractingSubtitles = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Extraction échouée : $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  Widget _buildInternalSubtitleList() {
    final subs = widget.session.subtitleTracks
        .where((t) => t.id != 'auto')
        .toList();
    final current = widget.session.currentSubtitleTrack;

    if (subs.isEmpty) {
      return const _EmptySubtitlesMessage();
    }

    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: 4),
      itemCount: subs.length,
      itemBuilder: (context, index) {
        final track = subs[index];
        final isSelected = track == current;
        final name = _subtitleTrackName(track, index);
        final (title, subtitle) = splitTrackLabel(name);

        return PlayerSettingsTrackRow(
          label: title,
          subtitle: subtitle,
          selected: isSelected,
          onTap: () {
            _controller.selectInternalSubtitle(track);
            widget.onSelected();
          },
        );
      },
    );
  }

  Widget _buildCanonicalSubtitleList(List<MediaSubtitleTrack> subtitles) {
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: 4),
      itemCount: subtitles.length + 1,
      itemBuilder: (context, row) {
        if (row == 0) {
          return PlayerSettingsTrackRow(
            label: 'Désactivés',
            selected: _controller.selectedSubtitleLang == null,
            onTap: () {
              _controller.setSubtitle(null);
              widget.onSelected();
            },
          );
        }
        final index = row - 1;
        final track = subtitles[index];
        final (title, subtitle) = splitTrackLabel(track.displayName);

        return PlayerSettingsTrackRow(
          label: title,
          subtitle: subtitle,
          // A bitmap track has nothing to extract, but while transcoding it can
          // only be shown by being painted into the video — so picking it costs
          // a short reload. Flag it so that pause is expected rather than read
          // as a stall.
          badge: !track.ready
              ? '…'
              : (track.image && _controller.currentQuality != null)
                  ? 'image'
                  : null,
          selected: _controller.selectedSubtitleLang == track.lang,
          onTap: () {
            _controller.setSubtitle(track.lang);
            widget.onSelected();
          },
        );
      },
    );
  }
}

class _EmptySubtitlesMessage extends StatelessWidget {
  const _EmptySubtitlesMessage();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Aucune piste disponible',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.45),
          fontSize: 13,
          fontFamily: 'Manrope',
        ),
      ),
    );
  }
}
