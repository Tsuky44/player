/// Reconnaître un téléviseur LG à son agent utilisateur.
///
/// C'est la seule chose que la page sait de l'appareil : l'app webOS n'est
/// qu'un lanceur qui ouvre l'app web servie par le serveur (ADR-0076), et
/// cette page-là n'a accès à aucune API du système. Le moteur de webOS
/// s'annonce « Web0S » — avec un zéro — depuis webOS 3, « webOS » sur les
/// premiers modèles ; l'un ou l'autre suffit, et rien d'autre ne l'écrit.
library;

final _webOS = RegExp(r'web0s|webos', caseSensitive: false);

bool isWebOSUserAgent(String userAgent) => _webOS.hasMatch(userAgent);
