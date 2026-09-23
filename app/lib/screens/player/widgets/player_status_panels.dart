// Les panneaux d'état du lecteur : ce qui remplace l'image quand elle ne
// vient pas, ou quand la lecture est ailleurs. Sortis de player_screen.dart.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/client_log.dart';
import '../playback/playback_session.dart';

/// Standalone back control, shown while the end-of-season page hides the rest
/// of the player chrome. Kept independent of the HUD so it cannot be swept away
/// with it.
class PlayerBackButton extends StatefulWidget {
  final VoidCallback onTap;

  const PlayerBackButton({super.key, required this.onTap});

  @override
  State<PlayerBackButton> createState() => _PlayerBackButtonState();
}

class _PlayerBackButtonState extends State<PlayerBackButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: _hovered ? 0.62 : 0.38),
            border: Border.all(
              color: _hovered ? Colors.white24 : Colors.white10,
            ),
          ),
          child: Icon(
            Icons.arrow_back_rounded,
            size: 20,
            color: _hovered ? Colors.white : Colors.white70,
          ),
        ),
      ),
    );
  }
}

/// La lecture a été reprise sur un autre appareil du compte : ce lecteur est
/// en pause et propose de la ramener ici.
class PlayingElsewhere extends StatelessWidget {
  final String deviceName;
  final bool busy;
  final VoidCallback onResume;
  final VoidCallback onBack;

  const PlayingElsewhere({
    super.key,
    required this.deviceName,
    required this.busy,
    required this.onResume,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.86),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.devices_rounded,
                  size: 54, color: Colors.white70),
              const SizedBox(height: 22),
              const Text(
                'Lecture en cours sur un autre appareil',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'La lecture continue sur « $deviceName ». Reprenez-la ici, '
                'là où il en est.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 15,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 28),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton.icon(
                    autofocus: true,
                    onPressed: busy ? null : onResume,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Reprendre la lecture ici'),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: onBack,
                    child: const Text('Quitter'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What replaces the start-up spinner once the picture is overdue.
///
/// The spinner is honest for twenty-five seconds and a lie after that: it says
/// "working on it" about a start-up that, by then, has usually stopped working
/// on anything. What actually helps is naming the likeliest cause — the link
/// between this screen and the server — and offering the one action that fixes
/// most of them, which is to open the whole thing again from scratch.
class StalledStartup extends StatelessWidget {
  /// Ce que le moteur a dit, quand il a dit quelque chose.
  ///
  /// Null veut dire que rien n'a échoué de façon visible et que c'est le délai
  /// de démarrage qui a parlé — le texte reste alors celui d'avant, qui nomme
  /// la cause la plus probable d'un démarrage qui n'aboutit pas.
  final PlaybackFailure? failure;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  const StalledStartup({
    super.key,
    required this.failure,
    required this.onRetry,
    required this.onBack,
  });

  /// La phrase qui explique, choisie sur ce que le moteur a rapporté.
  String get _explanation => switch (failure?.kind) {
        PlaybackFailureKind.unsupported =>
          'Cet appareil ne sait pas décoder ce fichier, et le transcodage '
              'n’a pas pris le relais. Réessayer relance les deux.',
        PlaybackFailureKind.source =>
          'Le serveur n’a pas pu livrer la vidéo. C’est presque toujours le '
              'réseau entre cet appareil et lui — réessayer suffit le plus '
              'souvent.',
        PlaybackFailureKind.unknown =>
          'Le lecteur a renoncé sans que la cause soit claire. Réessayer '
              'suffit le plus souvent.',
        null => 'Le serveur met trop longtemps à envoyer la vidéo. '
            'C’est presque toujours le réseau entre cet appareil et lui — '
            'réessayer suffit le plus souvent.',
      };

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.86),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.wifi_tethering_error_rounded,
                size: 54,
                color: Colors.white70,
              ),
              const SizedBox(height: 22),
              const Text(
                'La lecture ne démarre pas',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _explanation,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 15,
                  height: 1.45,
                ),
              ),
              // La ligne du moteur, telle quelle. Elle ne s'adresse pas au
              // spectateur mais à qui il enverra une capture d'écran : sans
              // elle, « ça ne se lance pas » reste la seule chose qu'on saura
              // d'une panne.
              if (failure != null) ...[
                const SizedBox(height: 14),
                Text(
                  failure!.message,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
              const SizedBox(height: 28),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton.icon(
                    // The remote lands here: it is the button that helps.
                    autofocus: true,
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Réessayer'),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: onBack,
                    child: const Text('Retour'),
                  ),
                ],
              ),
              // Le journal, à l'endroit et au moment où on en a besoin.
              // L'aller chercher dans les réglages suppose de quitter l'écran,
              // ce qui est exactement le geste qui fait perdre le contexte de
              // la panne qu'on essaie de rapporter.
              const SizedBox(height: 10),
              _CopyLogButton(),
            ],
          ),
        ),
      ),
    );
  }
}

/// « Copier le journal », avec sa confirmation sur place.
///
/// Un `StatefulWidget` pour la seule raison qu'un bouton qui ne dit rien après
/// un appui laisse croire qu'il n'a rien fait — et il n'y a pas de barre de
/// notification par-dessus le lecteur en plein écran.
class _CopyLogButton extends StatefulWidget {
  @override
  State<_CopyLogButton> createState() => _CopyLogButtonState();
}

class _CopyLogButtonState extends State<_CopyLogButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: ClientLog.export()));
        if (!mounted) return;
        setState(() => _copied = true);
      },
      icon: Icon(
        _copied ? Icons.check_rounded : Icons.copy_rounded,
        size: 16,
        color: Colors.white54,
      ),
      label: Text(
        _copied ? 'Journal copié' : 'Copier le journal',
        style: const TextStyle(color: Colors.white54, fontSize: 13),
      ),
    );
  }
}
