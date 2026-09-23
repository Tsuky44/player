import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/watch_party.dart';
import '../../../services/watch_party.dart';
import '../../../theme/app_colors.dart';

/// Le bouton « Regarder ensemble » des barres du lecteur : une icône parmi
/// les autres, qui ne se distingue que pendant une séance.
class WatchPartyBarButton extends StatelessWidget {
  const WatchPartyBarButton({
    super.key,
    required this.active,
    required this.onPressed,
    this.size = 40,
  });

  final bool active;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: active ? 'Séance en cours' : 'Regarder ensemble',
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? AppColors.accent.withValues(alpha: 0.25)
                  : Colors.white.withValues(alpha: 0.08),
              border: Border.all(
                color: active
                    ? AppColors.accent.withValues(alpha: 0.6)
                    : Colors.white.withValues(alpha: 0.12),
              ),
            ),
            alignment: Alignment.center,
            child: Icon(
              active ? Icons.groups_rounded : Icons.group_add_outlined,
              color: active ? AppColors.accentMuted : Colors.white,
              size: size * 0.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// L'annonce d'un geste venu d'un autre appareil — « Alex a mis en pause ».
///
/// Visible même quand les commandes sont masquées : c'est précisément quand on
/// ne touche à rien qu'il faut savoir pourquoi le film s'est arrêté.
class WatchPartyToast extends StatelessWidget {
  const WatchPartyToast({super.key, required this.message, required this.visible});

  final String? message;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible && message != null ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.groups_rounded,
                  size: 16, color: AppColors.accentMuted),
              const SizedBox(width: 8),
              Text(
                message ?? '',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Le panneau de la séance : la démarrer, ou en voir le code et les
/// participants, et la quitter.
class WatchPartyPanel extends StatefulWidget {
  const WatchPartyPanel({
    super.key,
    required this.party,
    required this.onStart,
    required this.onLeave,
    required this.onClose,
  });

  final WatchPartySession? party;

  /// Ouvre la séance sur le média en cours. Lève en cas d'échec.
  final Future<void> Function() onStart;
  final VoidCallback onLeave;
  final VoidCallback onClose;

  @override
  State<WatchPartyPanel> createState() => _WatchPartyPanelState();
}

class _WatchPartyPanelState extends State<WatchPartyPanel> {
  bool _starting = false;
  String? _error;
  bool _copied = false;

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      await widget.onStart();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = 'Impossible de démarrer la séance. Réessayez.';
      });
    }
  }

  Future<void> _copy(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final party = widget.party;
    return Container(
      width: 380,
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 20),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 32, offset: Offset(0, 12)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.groups_rounded, color: AppColors.accentMuted),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Regarder ensemble',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Fermer',
                onPressed: widget.onClose,
                icon: const Icon(Icons.close, color: AppColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: party == null ? _buildIdle() : _buildActive(party),
          ),
        ],
      ),
    );
  }

  Widget _buildIdle() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Lancez une séance et partagez son code. Chacun la rejoint depuis '
          'son appareil, avec son propre compte : lecture, pauses et '
          'déplacements sont partagés entre tous.',
          style: TextStyle(color: AppColors.textSecondary, height: 1.4),
        ),
        const SizedBox(height: 16),
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: AppColors.error)),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          onPressed: _starting ? null : _start,
          icon: _starting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_circle_outline),
          label: const Text('Démarrer une séance'),
        ),
      ],
    );
  }

  Widget _buildActive(WatchPartySession party) {
    return ListenableBuilder(
      listenable: party,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Code de la séance',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  party.code,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 6,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => _copy(party.code),
                icon: Icon(_copied ? Icons.check : Icons.copy_rounded, size: 18),
                label: Text(_copied ? 'Copié' : 'Copier'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Pour rejoindre : menu du compte › Rejoindre une séance.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          Text(
            party.members.length > 1
                ? '${party.members.length} participants'
                : 'En attente des autres participants…',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          for (final member in party.members) _MemberRow(member: member),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: widget.onLeave,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.error,
              side: BorderSide(color: AppColors.error.withValues(alpha: 0.5)),
            ),
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('Quitter la séance'),
          ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member});

  final WatchPartyMember member;

  @override
  Widget build(BuildContext context) {
    final name = member.username.isEmpty ? 'Invité' : member.username;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: AppColors.surfaceHover,
            child: Text(
              name[0].toUpperCase(),
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  member.isYou ? '$name (vous)' : name,
                  style: const TextStyle(color: AppColors.textPrimary),
                ),
                if (member.device != null)
                  Text(
                    member.device!,
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (member.isHost)
            const Text(
              'Hôte',
              style: TextStyle(color: AppColors.accentMuted, fontSize: 12),
            ),
        ],
      ),
    );
  }
}
