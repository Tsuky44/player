import 'package:dio/dio.dart';

import 'server_registry.dart';

/// The app carries watch history between its saved accounts. Each HTTP client
/// is bound to one account so switching servers cannot redirect credentials.
class ProgressSync {
  ProgressSync(this.servers, {Dio Function(BaseOptions)? clientFactory})
      : _clientFactory = clientFactory ?? ((options) => Dio(options));

  final ServerRegistry servers;
  final Dio Function(BaseOptions) _clientFactory;
  Future<void>? _running;
  DateTime? _lastSync;
  String? _lastAccounts;

  Future<void> synchronize(
      {bool force = false, String? sourceAccountId, int? mediaId}) async {
    while (_running != null) {
      await _running;
      if (!force) return;
    }
    final accountsKey = servers.accounts
        .map((a) =>
            '${a.id}:${servers.linkedAccounts(a.id).map((p) => p.id).join(',')}')
        .join('|');
    if (!force &&
        accountsKey == _lastAccounts &&
        _lastSync != null &&
        DateTime.now().difference(_lastSync!) < const Duration(seconds: 30)) {
      return;
    }
    final run = _synchronize(sourceAccountId: sourceAccountId, mediaId: mediaId)
        .catchError((Object _) {});
    _running = run;
    try {
      await run;
      if (sourceAccountId == null) {
        _lastSync = DateTime.now();
        _lastAccounts = accountsKey;
      }
    } on Object {
      // Local storage errors must not interrupt playback either.
    } finally {
      if (identical(_running, run)) _running = null;
    }
  }

  Future<void> _synchronize({String? sourceAccountId, int? mediaId}) async {
    final visited = <String>{};
    for (final account in servers.accounts) {
      if (visited.contains(account.id)) continue;
      final group = servers.linkedAccounts(account.id);
      visited.addAll(group.map((a) => a.id));
      if (group.length < 2 ||
          (sourceAccountId != null &&
              !group.any((a) => a.id == sourceAccountId))) {
        continue;
      }
      await _syncGroup(group.map((a) => a.id).toList(),
          sourceAccountId: sourceAccountId, mediaId: mediaId);
    }
  }

  Future<void> _syncGroup(List<String> ids,
      {String? sourceAccountId, int? mediaId}) async {
    final accounts = servers.accounts.where((a) => ids.contains(a.id)).toList();
    final clients = <String, Dio>{};
    final latest = <String, Map<String, dynamic>>{};
    try {
      await Future.wait(accounts.map((account) async {
        final token = await servers.tokenFor(account.id);
        if (token == null || token.isEmpty) return;
        final client = _clientFactory(BaseOptions(
          baseUrl: account.url,
          headers: {'Authorization': 'Bearer $token'},
          followRedirects: false,
          connectTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
        ));
        clients[account.id] = client;
        try {
          if (sourceAccountId != null && account.id != sourceAccountId) return;
          final response = await client
              .get('/api/progress/sync', queryParameters: {
            if (sourceAccountId != null && mediaId != null) 'media_id': mediaId
          });
          for (final raw in response.data as List) {
            final entry = Map<String, dynamic>.from(raw as Map);
            final key = '${entry['type']}:${entry['tmdb_id']}:'
                '${entry['season_number']}:${entry['episode_number']}';
            final date = DateTime.parse(entry['updated_at'] as String);
            final previous = latest[key];
            if (previous == null ||
                date.isAfter(
                    DateTime.parse(previous['updated_at'] as String))) {
              latest[key] = entry;
            }
          }
        } on Object {
          // Offline, expired session or older server: keep the other accounts
          // usable. The source keeps its history for the next attempt.
        }
      }));
      final entries = latest.values.toList();
      await Future.wait(clients.entries.map((target) async {
        if (servers.accountById(target.key) == null) return;
        // Unlinking while requests are in flight stops subsequent transfers.
        final currentGroup =
            servers.linkedAccounts(target.key).map((a) => a.id).toSet();
        if (!ids.every(currentGroup.contains)) return;
        try {
          for (var offset = 0; offset < entries.length; offset += 500) {
            final end = (offset + 500).clamp(0, entries.length);
            await target.value
                .post('/api/progress/sync', data: entries.sublist(offset, end));
          }
        } on Object {
          // The next refresh retries from the histories retained by servers.
        }
      }));
    } finally {
      for (final client in clients.values) {
        client.close();
      }
    }
  }
}
