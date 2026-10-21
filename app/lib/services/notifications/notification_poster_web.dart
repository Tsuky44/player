import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Le web n'affiche pas de notification système : jamais d'affiche.
class NotificationPoster {
  const NotificationPoster({required this.bytes, this.filePath});

  final Uint8List bytes;
  final String? filePath;

  static Future<NotificationPoster?> load(String? url, {Dio? dio}) async =>
      null;
}
