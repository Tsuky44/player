/// Ce qu'[openExternalUrl] accepte d'ouvrir.
///
/// Les liens viennent du serveur (installeurs, bandes-annonces) : un serveur
/// malveillant pouvait glisser un `javascript:` dans l'app web, ou un `&` que
/// `cmd /c start` exécutait comme une seconde commande sous Windows. Seul un
/// lien web absolu, sans espace ni caractère de contrôle, passe.
bool isOpenableExternalUrl(String url) {
  if (url.isEmpty || RegExp(r'[\s\x00-\x1f\x7f"]').hasMatch(url)) return false;
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return false;
  return uri.scheme == 'http' || uri.scheme == 'https';
}
