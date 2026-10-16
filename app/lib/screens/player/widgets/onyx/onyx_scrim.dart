import 'package:flutter/widgets.dart';

/// Le dégradé d'une barre du Chrome Onyx, peint *derrière* ses rangées et
/// transparent aux clics.
///
/// Un `Container` avec une décoration est un `DecoratedBox`, qui demande à la
/// décoration si un point est dedans — et pour un rectangle, c'est toujours
/// oui. Le dégradé avalait donc tout clic tombé dans la boîte de la barre, y
/// compris là où rien n'est dessiné : sur un desktop, maintenir le clic en haut
/// de l'image ne déplaçait pas la fenêtre, parce que la zone de l'image sous la
/// barre ne voyait jamais le pointeur. Seuls les boutons doivent répondre ici.
class OnyxScrim extends StatelessWidget {
  const OnyxScrim({super.key, required this.gradient, required this.child});

  final Gradient gradient;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(decoration: BoxDecoration(gradient: gradient)),
          ),
        ),
        child,
      ],
    );
  }
}
