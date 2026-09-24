import 'package:flutter/material.dart';

import '../../models/media_share.dart';
import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_deferred_keyboard.dart';
import '../../utils/format.dart';
import '../../utils/poster_url.dart';
import '../../widgets/global/app_network_image.dart';
import '../player/player_screen.dart';

/// La page d'un lien de partage : ce qu'il ouvre, son mot de passe s'il en a
/// un, et le bouton qui lance le lecteur Onyx (ADR-0037).
class SharedLinkScreen extends StatefulWidget {
  const SharedLinkScreen({super.key, required this.api});

  final SharedLinkApiClient api;

  @override
  State<SharedLinkScreen> createState() => _SharedLinkScreenState();
}

class _SharedLinkScreenState extends State<SharedLinkScreen> {
  final TextEditingController _password = TextEditingController();

  SharedMediaInfo? _info;
  bool _loading = true;
  bool _opening = false;

  /// Une erreur qui ferme le lien (inconnu, expiré, ouvert ailleurs).
  String? _fatal;

  /// Une erreur qu'on peut corriger : mauvais mot de passe, réseau.
  String? _error;
  int _resumeAt = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.api.code.isEmpty) {
      setState(() {
        _loading = false;
        _fatal = 'Il manque la fin de l’adresse. Demandez à la personne qui '
            'vous l’a envoyée de la copier à nouveau.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await widget.api.info();
      final resumeAt = await widget.api.savedPosition();
      if (!mounted) return;
      setState(() {
        // Une fois le mot de passe donné, garder ce que l'ouverture a appris :
        // la description anonyme ne nomme plus le média.
        _info = info.title.isEmpty && (_info?.title.isNotEmpty ?? false)
            ? _info
            : info;
        _resumeAt = resumeAt;
        _fatal = null;
        _loading = false;
      });
    } on SharedLinkException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (e.status == 0) {
          _error = e.message;
        } else {
          _fatal = e.message;
        }
      });
    }
  }

  Future<void> _watch() async {
    final info = _info;
    if (info == null || _opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final opened = await widget.api.open(_password.text);
      if (!mounted) return;
      setState(() {
        _info = opened.media;
        _opening = false;
      });
      final media = Media(
        id: opened.mediaId,
        type: opened.media.mediaType == 'episode'
            ? MediaType.episode
            : MediaType.movie,
        title: opened.media.subtitle.isEmpty
            ? opened.media.title
            : '${opened.media.title} · ${opened.media.subtitle}',
        duration: opened.media.duration,
        posterUrl: opened.media.posterUrl,
        createdAt: DateTime.now(),
      );
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          media: media,
          resumeAtSeconds: _resumeAt,
        ),
      ));
      if (mounted) await _load();
    } on SharedLinkException catch (e) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        if (e.status == 401 || e.status == 429 || e.status == 0) {
          _error = e.message;
        } else {
          _fatal = e.message;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final poster =
        resolvePosterUrl(info?.posterUrl, serverBaseUrl: widget.api.baseUrl);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: LayoutBuilder(builder: (context, constraints) {
                final narrow = constraints.maxWidth < 560;
                final cover = _Poster(url: poster, width: narrow ? 150 : 200);
                final details = _buildDetails(info, centered: narrow);
                return DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(narrow ? 20 : 28),
                    child: narrow
                        ? Column(children: [
                            cover,
                            const SizedBox(height: 20),
                            details,
                          ])
                        : Row(children: [
                            cover,
                            const SizedBox(width: 28),
                            Expanded(child: details),
                          ]),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetails(SharedMediaInfo? info, {required bool centered}) {
    final align =
        centered ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final textAlign = centered ? TextAlign.center : TextAlign.start;
    final title = _fatal != null
        ? 'Lien indisponible'
        : info == null
            ? (_loading ? 'Chargement…' : 'Lien indisponible')
            : info.title.isNotEmpty
                ? info.title
                : 'Contenu protégé';
    final badges = [
      if (info != null && info.duration > 0) formatDuration(info.duration),
      if (info != null && info.singleUse) 'Lien à usage unique',
    ];
    final needsPassword = info?.needsPassword ?? false;

    return Column(
      crossAxisAlignment: align,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Onyx · Partagé avec vous',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          title,
          textAlign: textAlign,
          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
        ),
        if (info != null && info.subtitle.isNotEmpty && _fatal == null) ...[
          const SizedBox(height: 8),
          Text(
            info.subtitle,
            textAlign: textAlign,
            style:
                const TextStyle(color: AppColors.textSecondary, fontSize: 16),
          ),
        ],
        if (badges.isNotEmpty && _fatal == null) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: centered ? WrapAlignment.center : WrapAlignment.start,
            children: [for (final label in badges) _Badge(label)],
          ),
        ],
        const SizedBox(height: 22),
        if (_fatal != null)
          Text(_fatal!,
              textAlign: textAlign,
              style: const TextStyle(color: AppColors.textSecondary))
        else if (info != null) ...[
          if (needsPassword) ...[
            TvDeferredKeyboard(
              builder: (context, focusNode, canRequestFocus) => TextField(
                controller: _password,
                focusNode: focusNode,
                canRequestFocus: canRequestFocus,
                autofocus: true,
                obscureText: true,
                enabled: !_opening,
                maxLength: 72,
                decoration: const InputDecoration(
                  labelText: 'Mot de passe',
                  helperText: 'Ce lien est protégé par un mot de passe.',
                  counterText: '',
                ),
                onSubmitted: (_) => _watch(),
              ),
            ),
            const SizedBox(height: 16),
          ],
          SizedBox(
            width: centered ? double.infinity : null,
            height: 48,
            child: FilledButton.icon(
              autofocus: !needsPassword,
              onPressed: _opening ? null : _watch,
              icon: _opening
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded),
              label: Text(_resumeAt > 30
                  ? 'Reprendre à ${formatPlaybackTime(_resumeAt)}'
                  : 'Regarder'),
            ),
          ),
        ] else if (_loading)
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              textAlign: textAlign,
              style: const TextStyle(color: AppColors.error)),
          if (info == null) ...[
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('Réessayer')),
          ],
        ],
      ],
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.url, required this.width});

  final String? url;
  final double width;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      color: AppColors.surfaceElevated,
      alignment: Alignment.center,
      child: Icon(Icons.movie_outlined,
          size: width * 0.35, color: AppColors.textMuted),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: width,
        height: width * 1.5,
        child: url == null
            ? fallback
            : AppNetworkImage(
                url: url!,
                placeholder: fallback,
                errorWidget: fallback,
              ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
