import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../models/server_account.dart';
import 'server_registry.dart';

class MediaRelay {
  const MediaRelay(this.account, this.media, {this.resumeAtSeconds = 0});
  final int resumeAtSeconds;
  final ServerAccount account;
  final Media media;
}

/// Resolves content with credentials scoped to each linked account. Identity
/// snapshots survive restarts, because the failed source cannot answer a lookup.
class MediaFailover {
  MediaFailover(this.servers, {Dio Function(BaseOptions)? clientFactory})
      : _clientFactory = clientFactory ?? ((options) => Dio(options));
  final ServerRegistry servers;
  final Dio Function(BaseOptions) _clientFactory;
  final _refreshing = <String, Future<void>>{};
  final _refreshedAt = <String, DateTime>{};

  Future<Dio?> _client(String id) async {
    final account = servers.accountById(id);
    final token = await servers.tokenFor(id);
    if (account == null || token == null || token.isEmpty) return null;
    return _clientFactory(BaseOptions(
      baseUrl: account.url,
      headers: {'Authorization': 'Bearer $token'},
      followRedirects: false,
      connectTimeout: const Duration(seconds: 3),
      receiveTimeout: const Duration(seconds: 4),
      sendTimeout: const Duration(seconds: 4),
    ));
  }

  Future<void> refreshIdentities(String id) async {
    if (servers.linkedAccounts(id).length < 2) return;
    if (_refreshing[id] != null) return _refreshing[id];
    final last = _refreshedAt[id];
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 5)) {
      return;
    }
    final task = _refresh(id);
    _refreshing[id] = task;
    try {
      await task;
    } finally {
      _refreshing.remove(id);
    }
  }

  Future<void> _refresh(String id) async {
    Dio? client;
    try {
      client = await _client(id);
      if (client == null) return;
      final response = await client.get('/api/media-identities');
      if (response.data is! Map) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('media_identities_$id', jsonEncode(response.data));
      _refreshedAt[id] = DateTime.now();
    } on Object {
      // Keep the last successful snapshot when the server is unavailable.
    } finally {
      client?.close();
    }
  }

  Future<bool> _available(String id) async {
    Dio? client;
    try {
      client = await _client(id);
      if (client == null) return false;
      final response = await client.get('/api/ping');
      return response.statusCode == 200;
    } on Object {
      return false;
    } finally {
      client?.close();
    }
  }

  Future<MediaRelay?> findReplacement(
      {required String sourceAccountId,
      required Media media,
      Set<String> excluded = const {}}) async {
    final peers = servers
        .linkedAccounts(sourceAccountId)
        .where((a) => a.id != sourceAccountId && !excluded.contains(a.id))
        .toList();
    if (peers.isEmpty || await _available(sourceAccountId)) return null;
    Map<String, dynamic>? identity;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('media_identities_$sourceAccountId');
      if (raw != null) {
        final saved = (jsonDecode(raw) as Map)[media.id.toString()];
        if (saved is Map) identity = Map<String, dynamic>.from(saved);
      }
    } on Object {/* A missing identity must never become a title match. */}
    if (identity == null &&
        media.type == MediaType.movie &&
        (media.tmdbId ?? 0) > 0) {
      identity = {
        'type': 'movie',
        'tmdb_id': media.tmdbId,
        'season_number': 0,
        'episode_number': 0
      };
    }
    if (identity == null) return null;
    final results = await Future.wait(peers.map((peer) async {
      Dio? client;
      try {
        client = await _client(peer.id);
        if (client == null) return null;
        final response =
            await client.post('/api/media-resolve', data: identity);
        final resolved =
            Media.fromJson(Map<String, dynamic>.from(response.data as Map));
        if (resolved.id <= 0 || resolved.type != media.type) return null;
        return MediaRelay(peer, resolved,
            resumeAtSeconds: response.data['is_finished'] == true
                ? 0
                : (response.data['current_position_seconds'] as int? ?? 0));
      } on Object {
        return null;
      } finally {
        client?.close();
      }
    }));
    final stillLinked =
        servers.linkedAccounts(sourceAccountId).map((a) => a.id).toSet();
    for (final result in results) {
      if (result != null && stillLinked.contains(result.account.id)) {
        return result;
      }
    }
    return null;
  }
}
