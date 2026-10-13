import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/tr.dart';
import '../../models/media.dart';
import '../../models/server_account.dart';

/// Un épisode tout juste sorti d'une série que l'on suit, sur un des serveurs
/// de l'appareil : ce qu'une notification annonce (ADR-0059).
class NewEpisodeAlert {
  const NewEpisodeAlert({
    required this.accountId,
    required this.serverName,
    required this.showId,
    required this.showTitle,
    this.posterUrl,
    this.season,
    this.episode,
  });

  /// L'entrée de « À reprendre » que le serveur a marquée `has_new_episode`,
  /// ou null si elle ne désigne pas une série.
  static NewEpisodeAlert? fromItem(ServerAccount account, HomeMediaItem item) {
    final showId = item.showId;
    if (!item.hasNewEpisode || showId == null || showId <= 0) return null;
    return NewEpisodeAlert(
      accountId: account.id,
      serverName: account.displayName,
      showId: showId,
      showTitle: item.showTitle ?? item.media.title,
      posterUrl: item.showPosterUrl,
      season: item.media.seasonNumber,
      episode: item.media.episodeNumber,
    );
  }

  final String accountId;
  final String serverName;

  /// Propre au serveur de [accountId] : ce nombre ne veut rien dire ailleurs.
  final int showId;
  final String showTitle;
  final String? posterUrl;
  final int? season;
  final int? episode;

  /// Ce qui fait qu'un épisode n'est annoncé qu'une fois. Le numéro plutôt que
  /// l'identifiant du fichier : un épisode remplacé par une meilleure copie
  /// change d'identifiant, pas de numéro, et ne mérite pas une seconde
  /// notification.
  String get key => '$showId:${season ?? 0}x${episode ?? 0}';

  /// L'identifiant de la notification, stable d'un lancement à l'autre : la
  /// même annonce affichée deux fois se remplace au lieu de s'empiler.
  /// `String.hashCode` ne promet pas cette stabilité, d'où le FNV-1a.
  int get notificationId {
    var hash = 0x811c9dc5;
    for (final unit in '$accountId|$key'.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }

  /// Le texte sous le titre de la série. Le serveur n'est nommé que s'il y en
  /// a plusieurs ([nameServer]) : avec un seul, il n'apprend rien.
  String body({required bool nameServer}) {
    final what = season != null && episode != null
        ? tr('Nouvel épisode · S{0} · Épisode {1}', [season, episode])
        : tr('Nouvel épisode disponible');
    return nameServer ? tr('{0} — sur {1}', [what, serverName]) : what;
  }

  String toPayload() => jsonEncode({
        'account': accountId,
        'server': serverName,
        'show_id': showId,
        'title': showTitle,
        if (posterUrl != null) 'poster': posterUrl,
        if (season != null) 'season': season,
        if (episode != null) 'episode': episode,
      });

  /// Relit ce que [toPayload] a écrit. Null pour une charge illisible : une
  /// notification d'une version précédente ouvre l'app, sans plus.
  static NewEpisodeAlert? fromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      return NewEpisodeAlert(
        accountId: data['account'] as String,
        serverName: data['server'] as String? ?? '',
        showId: data['show_id'] as int,
        showTitle: data['title'] as String? ?? '',
        posterUrl: data['poster'] as String?,
        season: data['season'] as int?,
        episode: data['episode'] as int?,
      );
    } on Object {
      return null;
    }
  }
}

/// Ce qui a déjà été annoncé, par compte.
///
/// Dans les préférences parce que deux isolats l'écrivent : l'app ouverte et
/// la tâche de fond, qui tourne dans son propre moteur. Chacun garde sa copie
/// des préférences en mémoire, d'où le `reload()` avant chaque lecture.
class NewEpisodeLedger {
  const NewEpisodeLedger();

  static const String _key = 'new_episode_alerts_seen_v1';

  /// Plafond par compte. Le serveur ne garde le drapeau que trois semaines :
  /// au-delà de quelques dizaines de clés, les plus anciennes ne reviendront
  /// plus.
  static const int maxPerAccount = 100;

  Future<Map<String, List<String>>> read() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      return {
        for (final entry in (jsonDecode(raw) as Map<String, dynamic>).entries)
          entry.key: (entry.value as List).cast<String>().toList(),
      };
    } on Object {
      // Un registre illisible vaut un registre vide : le prochain passage
      // refait un état des lieux silencieux, il ne rejoue aucune annonce.
      return {};
    }
  }

  Future<void> write(Map<String, List<String>> seen) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(seen));
  }
}

/// Fait le tour des serveurs de l'appareil et rend les épisodes à annoncer.
///
/// Ne décide pas de ce qui est « nouveau » : c'est le serveur, par
/// `has_new_episode` sur « À reprendre ». Cette classe ne retient que ce
/// qu'elle a déjà dit, pour ne le dire qu'une fois.
class NewEpisodeWatch {
  NewEpisodeWatch({
    required this.accounts,
    required this.fetch,
    this.ledger = const NewEpisodeLedger(),
    this.timeout = const Duration(seconds: 20),
  });

  /// Les comptes du carnet au moment du passage.
  final List<ServerAccount> Function() accounts;

  /// « À reprendre » d'un compte. Lève quand le serveur ne répond pas.
  final Future<List<HomeMediaItem>> Function(ServerAccount account) fetch;
  final NewEpisodeLedger ledger;

  /// iOS n'accorde qu'une trentaine de secondes à une tâche de fond : un
  /// serveur qui traîne ne doit pas emporter la réponse des autres.
  final Duration timeout;

  /// Les épisodes à annoncer maintenant.
  ///
  /// Les comptes de [quiet] sont enregistrés sans rien annoncer : c'est le
  /// serveur que l'app a sous les yeux, où la pastille « Nouvel épisode » de
  /// l'accueil dit déjà la même chose.
  Future<List<NewEpisodeAlert>> check({Set<String> quiet = const {}}) async {
    final current = accounts();
    final seen = await ledger.read();
    // Un compte retiré de l'appareil emporte ce qu'on avait retenu de lui.
    seen.removeWhere((id, _) => !current.any((account) => account.id == id));

    final answers = await Future.wait(current.map((account) async {
      try {
        return await fetch(account).timeout(timeout);
      } on Object catch (error) {
        // Hors de portée (serveur local depuis la 4G), session expirée, délai :
        // on n'a rien appris de ce serveur, le prochain passage réessaiera.
        debugPrint('NewEpisodeWatch: ${account.prettyHost} muet ($error)');
        return null;
      }
    }));

    final alerts = <NewEpisodeAlert>[];
    for (var i = 0; i < current.length; i++) {
      final items = answers[i];
      if (items == null) continue;
      final account = current[i];
      final known = seen[account.id];
      // Premier regard sur ce compte : ce qui est déjà là est un état des
      // lieux, pas une nouveauté. Sans cela, activer les notifications
      // annoncerait d'un coup tout ce que l'accueil affiche depuis des jours.
      final firstLook = known == null;
      final keys = known ?? <String>[];
      for (final item in items) {
        final alert = NewEpisodeAlert.fromItem(account, item);
        if (alert == null || keys.contains(alert.key)) continue;
        keys.add(alert.key);
        if (!firstLook && !quiet.contains(account.id)) alerts.add(alert);
      }
      seen[account.id] = keys.length > NewEpisodeLedger.maxPerAccount
          ? keys.sublist(keys.length - NewEpisodeLedger.maxPerAccount)
          : keys;
    }
    await ledger.write(seen);
    return alerts;
  }
}
