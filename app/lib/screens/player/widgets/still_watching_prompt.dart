import 'package:flutter/material.dart';

import '../../../theme/app_type.dart';

/// « Vous regardez encore ? » : ce qui prend l'écran quand plusieurs épisodes
/// se sont enchaînés sans que personne ne touche au lecteur (ADR-0045).
///
/// La lecture est en pause dessous et n'en sort que par une réponse. Il n'y a
/// pas de compte à rebours : une question qui se répondrait toute seule ne
/// protégerait pas celui qui dort.
class StillWatchingPrompt extends StatefulWidget {
  final VoidCallback onContinue;
  final VoidCallback onLeave;

  const StillWatchingPrompt({
    super.key,
    required this.onContinue,
    required this.onLeave,
  });

  @override
  State<StillWatchingPrompt> createState() => _StillWatchingPromptState();
}

class _StillWatchingPromptState extends State<StillWatchingPrompt> {
  final FocusNode _continueFocus =
      FocusNode(debugLabel: 'still-watching-continue');

  @override
  void initState() {
    super.initState();
    // Demandé, pas `autofocus` : le lecteur tient déjà le focus, et un
    // autofocus ne le prend qu'à une portée où rien n'est focalisé. Sans cela
    // la télécommande n'aurait aucun bouton sous OK.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _continueFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _continueFocus.dispose();
    super.dispose();
  }

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
              const Icon(Icons.bedtime_outlined,
                  size: 54, color: Colors.white70),
              const SizedBox(height: 22),
              const Text(
                'Vous regardez encore ?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: AppType.title2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Plusieurs épisodes se sont enchaînés sans que personne ne '
                'touche au lecteur. La lecture est en pause.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: AppType.callout,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 28),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    focusNode: _continueFocus,
                    onPressed: widget.onContinue,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Continuer la lecture'),
                  ),
                  TextButton(
                    onPressed: widget.onLeave,
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
