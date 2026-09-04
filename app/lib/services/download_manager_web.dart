/// Stub web du gestionnaire de téléchargements — voir `download_manager.dart`.
library;

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../models/offline_chrome.dart';
import '../models/offline_download.dart';
import 'api_client.dart';

/// Même surface que la version native, mais vide : [isSupported] est faux, la
/// liste ne se remplit jamais et chaque action est sans effet. Les écrans n'ont
/// donc pas à savoir sur quelle plateforme ils tournent — ils regardent
/// [isSupported].
class DownloadManager extends ChangeNotifier {
  DownloadManager._();

  static final DownloadManager instance = DownloadManager._();

  bool get isSupported => false;
  bool get isReady => true;

  List<OfflineDownload> get downloads => const [];
  int get pendingSyncCount => 0;
  int get totalBytesOnDisk => 0;

  Future<void> initialize(ApiClient api) async {}

  OfflineDownload? entryFor(int mediaId) => null;
  bool isDownloaded(int mediaId) => false;
  String? localVideoPath(int mediaId) => null;
  String? localPosterPath(int mediaId) => null;
  Map<String, dynamic>? offlineTracks(int mediaId) => null;
  Future<String?> offlineSubtitle(int mediaId, String lang) async => null;
  int? localResumeSeconds(int mediaId) => null;
  MediaDetails? offlineDetails(int mediaId) => null;
  MediaDetails? detailsForShow(int infoId) => null;
  String? showPosterPath(int infoId) => null;
  String? showLogoPath(int infoId) => null;
  OfflineChrome? chromeFor(int mediaId) => null;
  Future<void> rememberChrome(OfflineChrome chrome) async {}

  Future<void> download(
    HomeMediaItem item, {
    String? showTitle,
    int? showId,
    int? seasonNumber,
    String? showPosterUrl,
  }) async {}

  Future<void> pause(int mediaId) async {}
  Future<void> resume(int mediaId) async {}
  Future<void> delete(int mediaId) async {}
  Future<int> deleteWatched() async => 0;

  Future<void> recordProgress({
    required int mediaId,
    required int positionSeconds,
    required int durationSeconds,
    required bool isFinished,
    bool syncedWithServer = false,
  }) async {}

  Future<void> syncPending() async {}
  Future<void> onServerReachable() async {}
}
