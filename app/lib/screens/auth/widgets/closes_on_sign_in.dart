import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart';

/// Referme la page qu'il enveloppe dès qu'une session s'ouvre.
///
/// Le formulaire de mot de passe du téléviseur est poussé par-dessus l'écran du
/// QR. Une fois la connexion réussie, la racine remplace bien cet écran par
/// l'accueil — mais en dessous : la page poussée restait au-dessus, et la
/// personne voyait le formulaire comme si rien ne s'était passé.
class ClosesOnSignIn extends StatefulWidget {
  final Widget child;

  const ClosesOnSignIn({super.key, required this.child});

  @override
  State<ClosesOnSignIn> createState() => _ClosesOnSignInState();
}

class _ClosesOnSignInState extends State<ClosesOnSignIn> {
  late final AuthProvider _auth = context.read<AuthProvider>();
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (_closed || !_auth.isAuthenticated || !mounted) return;
    _closed = true;
    // Un dialogue (le code à usage unique) peut encore être au-dessus : on
    // retire cette page où qu'elle soit dans la pile.
    final route = ModalRoute.of(context);
    if (route == null) return;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
