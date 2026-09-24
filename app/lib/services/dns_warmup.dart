/// Garde les noms des serveurs dans le cache DNS du système — voir
/// l'implémentation io. Sans objet sur le web, où le navigateur s'en charge.
library;

export 'dns_warmup_io.dart' if (dart.library.js_interop) 'dns_warmup_web.dart';
