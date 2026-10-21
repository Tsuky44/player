import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/tr.dart';
import '../../models/media_request.dart';
import '../../models/request_feed.dart';
import '../../models/server_account.dart';

/// Une demande faite par un autre compte, sur un serveur que l'appareil
/// administre : ce qu'une notification annonce (ADR-0077).
class NewRequestAlert {
  const NewRequestAlert({
    required this.accountId,
    required this.serverName,
    required this.entry,
  });

  final String accountId;
  final String serverName;
  final RequestFeedEntry entry;

  /// Stable d'un passage à l'autre : la même demande annoncée deux fois se
  /// remplace au lieu de s'empiler. FNV-1a, comme [NewEpisodeAlert], parce que
  /// `String.hashCode` ne promet pas cette stabilité.
  int get notificationId {
    var hash = 0x811c9dc5;
    for (final unit in 'request|$accountId|${entry.id}'.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }

  String get title => tr('Nouvelle demande de {0}', [entry.requester]);

  /// Le titre, puis « Film » ou les saisons demandées. Le serveur n'est nommé
  /// que s'il y en a plusieurs ([nameServer]).
  String body({required bool nameServer}) {
    final seasons = entry.seasons;
    final what = entry.mediaType == RequestMediaType.movie || seasons.isEmpty
        ? tr('Film')
        : seasons.length == 1
            ? tr('Saison {0}', ['${seasons.first}'])
            : tr('Saisons {0}', [seasons.join(', ')]);
    final text = '${entry.title} · $what';
    return nameServer ? tr('{0} — sur {1}', [text, serverName]) : text;
  }
}

/// Le curseur du flux de chaque compte, rendu par OnyxHub au passage
/// précédent.
///
/// Dans les préférences, comme [NewEpisodeLedger] et pour la même raison :
/// l'app ouverte et la tâche de fond l'écrivent chacune depuis son isolat.
class RequestFeedLedger {
  const RequestFeedLedger();

  static const String _key = 'request_alerts_cursor_v1';

  Future<Map<String, int>> read() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>)
          .map((id, cursor) => MapEntry(id, (cursor as num).toInt()));
    } on Object {
      // Un curseur perdu vaut un premier passage : OnyxHub repose le curseur
      // au bout sans rien annoncer, rien n'est rejoué.
      return {};
    }
  }

  Future<void> write(Map<String, int> cursors) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(cursors));
  }
}

/// Fait le tour des serveurs de l'appareil et rend les demandes à annoncer.
///
/// Ne décide ni qui est administrateur (le serveur répond 403 aux autres) ni
/// ce qui est nouveau (OnyxHub, par le curseur). Elle ne retient que le
/// curseur de chaque compte.
class RequestAlertWatch {
  RequestAlertWatch({
    required this.accounts,
    required this.fetch,
    this.ledger = const RequestFeedLedger(),
    this.timeout = const Duration(seconds: 20),
  });

  /// Les comptes du carnet au moment du passage.
  final List<ServerAccount> Function() accounts;

  /// Le flux d'un compte depuis [after] ; null quand ce compte n'en a pas.
  /// Lève quand le serveur ne répond pas.
  final Future<RequestFeed?> Function(ServerAccount account, int? after) fetch;
  final RequestFeedLedger ledger;

  /// La même borne que [NewEpisodeWatch] : iOS n'accorde qu'une trentaine de
  /// secondes à la tâche de fond.
  final Duration timeout;

  Future<List<NewRequestAlert>> check() async {
    final current = accounts();
    final cursors = await ledger.read();
    cursors.removeWhere((id, _) => !current.any((account) => account.id == id));

    final answers = await Future.wait(current.map((account) async {
      try {
        return (
          ok: true,
          feed: await fetch(account, cursors[account.id]).timeout(timeout)
        );
      } on Object catch (error) {
        // Hors de portée, session expirée, OnyxHub muet : on garde le curseur,
        // et le passage suivant rattrape ce qui a été demandé entre-temps.
        debugPrint('RequestAlertWatch: ${account.prettyHost} muet ($error)');
        return (ok: false, feed: null);
      }
    }));

    final alerts = <NewRequestAlert>[];
    for (var i = 0; i < current.length; i++) {
      final answer = answers[i];
      if (!answer.ok) continue;
      final account = current[i];
      final feed = answer.feed;
      if (feed == null) {
        // Plus administrateur, ou OnyxHub débranché : s'il revient, ce sera
        // un premier passage, sans rejouer ce qui s'est passé entre-temps.
        cursors.remove(account.id);
        continue;
      }
      // Sans curseur, OnyxHub ne rend rien ; la garde tient même si un
      // serveur se mettait à rendre l'historique.
      if (cursors.containsKey(account.id)) {
        alerts.addAll(feed.requests.map((entry) => NewRequestAlert(
              accountId: account.id,
              serverName: account.displayName,
              entry: entry,
            )));
      }
      cursors[account.id] = feed.cursor;
    }
    await ledger.write(cursors);
    return alerts;
  }
}
