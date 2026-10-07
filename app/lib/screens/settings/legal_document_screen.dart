import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_type.dart';
import '../../widgets/global/empty_state.dart';
import '../../l10n/tr.dart';

/// Un texte légal embarqué dans l'app, lu depuis `assets/legal/`.
///
/// Embarqué plutôt qu'ouvert dans un navigateur : un téléviseur n'en a pas, et
/// l'app doit pouvoir montrer sa politique de confidentialité hors ligne.
enum LegalDocument {
  privacy('Politique de confidentialité', 'assets/legal/confidentialite.txt'),
  terms('Conditions d’utilisation', 'assets/legal/conditions.txt');

  const LegalDocument(this._title, this.asset);

  final String _title;

  String get title => tr(_title);
  final String asset;
}

class LegalDocumentScreen extends StatefulWidget {
  const LegalDocumentScreen({super.key, required this.document});

  final LegalDocument document;

  @override
  State<LegalDocumentScreen> createState() => _LegalDocumentScreenState();
}

class _LegalDocumentScreenState extends State<LegalDocumentScreen> {
  /// Un pas de télécommande : assez pour avancer, pas assez pour sauter un
  /// paragraphe.
  static const double _remoteStep = 160;

  final ScrollController _scroll = ScrollController();
  late Future<String> _text = _load();

  Future<String> _load() => rootBundle.loadString(widget.document.asset);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Le texte n'a rien de focalisable : sans ceci, le D-pad d'un téléviseur ne
  /// le ferait pas défiler.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !_scroll.hasClients) {
      return KeyEventResult.ignored;
    }
    final double delta;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      delta = _remoteStep;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      delta = -_remoteStep;
    } else {
      return KeyEventResult.ignored;
    }
    final position = _scroll.position;
    final target = (position.pixels + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: AppMotion.move(context, AppMotion.micro),
      curve: AppMotion.curve,
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(widget.document.title)),
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: FutureBuilder<String>(
          future: _text,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return ErrorStateView(
                message: tr('Ce document est introuvable dans cette version.'),
                onRetry: () => setState(() => _text = _load()),
              );
            }
            final text = snapshot.data;
            if (text == null) return const LoadingView();
            return SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: AppType.body,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
