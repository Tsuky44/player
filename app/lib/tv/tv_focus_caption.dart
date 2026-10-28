import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_motion.dart';
import '../theme/app_type.dart';
import 'tv_mode.dart';

/// Sur un téléviseur, écrit sous une rangée d'icônes le nom de celle qui a le
/// focus.
///
/// Les actions d'une fiche — vu, liste, télécharger, partager, corriger — sont
/// des icônes nues. À la souris, leur infobulle les nomme au survol ; à la
/// télécommande il n'y a pas de survol, et l'on devait deviner ce que faisait
/// le disque entouré. Le nom vient de l'infobulle ([Tooltip.message]) que le
/// bouton porte déjà : rien à déclarer deux fois.
///
/// Hors téléviseur, rend [child] tel quel.
class TvFocusCaption extends StatefulWidget {
  const TvFocusCaption({super.key, required this.child});

  final Widget child;

  @override
  State<TvFocusCaption> createState() => _TvFocusCaptionState();
}

class _TvFocusCaptionState extends State<TvFocusCaption> {
  final FocusNode _group = FocusNode(
    debugLabel: 'tv-focus-caption',
    canRequestFocus: false,
    skipTraversal: true,
  );
  final GlobalKey _rowKey = GlobalKey();

  String? _caption;

  /// Le centre horizontal de l'icône nommée, depuis le bord gauche du groupe.
  double _centerX = 0;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_update);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_update);
    _group.dispose();
    super.dispose();
  }

  void _update() {
    if (!mounted) return;
    String? caption;
    var centerX = _centerX;
    final focused = FocusManager.instance.primaryFocus;
    final focusedContext = focused?.context;
    if (focused != null &&
        focusedContext != null &&
        focused.ancestors.contains(_group)) {
      final tooltip = focusedContext.findAncestorWidgetOfExactType<Tooltip>();
      caption = tooltip?.message;
      final box = focusedContext.findRenderObject();
      final row = _rowKey.currentContext?.findRenderObject();
      if (box is RenderBox && row is RenderBox && box.attached) {
        final offset = box.localToGlobal(Offset.zero, ancestor: row);
        centerX = offset.dx + box.size.width / 2;
      }
    }
    if (caption == _caption && centerX == _centerX) return;
    setState(() {
      _caption = caption;
      if (caption != null) _centerX = centerX;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!TvScope.of(context)) return widget.child;
    final caption = _caption;
    return Focus(
      focusNode: _group,
      canRequestFocus: false,
      skipTraversal: true,
      child: Column(
        key: _rowKey,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          widget.child,
          // Hauteur réservée même vide : la ligne ne doit pas pousser la page
          // à chaque pas de la télécommande.
          SizedBox(
            height: 28,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: _centerX,
                  top: 8,
                  child: FractionalTranslation(
                    translation: const Offset(-0.5, 0),
                    child: AnimatedOpacity(
                      opacity: caption == null ? 0 : 1,
                      duration: AppMotion.fade(context),
                      curve: AppMotion.curve,
                      child: Text(
                        caption ?? '',
                        maxLines: 1,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: AppType.footnote,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
