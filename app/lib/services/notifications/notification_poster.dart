/// L'affiche jointe à une notification — voir l'implémentation io. Sans
/// objet sur le web, qui n'affiche pas ces notifications.
library;

export 'notification_poster_io.dart'
    if (dart.library.js_interop) 'notification_poster_web.dart';
