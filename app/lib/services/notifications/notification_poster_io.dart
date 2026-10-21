import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// L'affiche d'un média, téléchargée pour être jointe à une notification
/// (ADR-0077).
///
/// Android la prend en octets ; iOS ne joint qu'un fichier, qu'il déplace
/// ensuite dans son propre stockage — d'où [filePath], écrit sur iPhone
/// seulement et jamais à nettoyer.
class NotificationPoster {
  const NotificationPoster({required this.bytes, this.filePath});

  final Uint8List bytes;
  final String? filePath;

  /// Une affiche w342 pèse quelques dizaines de Ko. Au-delà, ce n'est pas
  /// une affiche, et le canal vers Android n'a pas à la porter.
  static const int _maxBytes = 2 << 20;

  /// Null sans adresse, ou quand l'image n'arrive pas : la notification part
  /// alors sans affiche plutôt que pas du tout. Le délai est court parce
  /// qu'iOS n'accorde qu'une trentaine de secondes à toute la tâche de fond.
  static Future<NotificationPoster?> load(String? url, {Dio? dio}) async {
    if (url == null) return null;
    final client = dio ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 6),
        ));
    try {
      final response = await client.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      final type = response.headers.value(Headers.contentTypeHeader) ?? '';
      if (data == null || data.isEmpty || data.length > _maxBytes) return null;
      if (!type.startsWith('image/')) return null;
      final bytes = Uint8List.fromList(data);
      return NotificationPoster(
        bytes: bytes,
        filePath: Platform.isIOS ? await _writeForIOS(url, bytes) : null,
      );
    } on Object catch (error) {
      debugPrint('NotificationPoster: affiche non chargée ($error)');
      return null;
    } finally {
      if (dio == null) client.close();
    }
  }

  static Future<String> _writeForIOS(String url, Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    // Un nom par affiche : deux notifications de suite ne se disputent pas
    // le même fichier, qu'iOS déplace au moment de l'afficher.
    final name = '${url.hashCode.toUnsigned(32)}'
        '_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final file = File('${dir.path}/notification_poster_$name');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
