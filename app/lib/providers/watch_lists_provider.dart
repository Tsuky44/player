import 'dart:async';

import 'package:flutter/foundation.dart';

import '../l10n/tr.dart';
import '../models/watch_list.dart';
import '../services/api_client.dart';

/// Les listes du compte et celles que les autres partagent (ADR-0070).
///
/// Le serveur tient tout : ce qui est ici n'est que le dernier état reçu,
/// relu après chaque écriture. Une liste ouverte garde son contenu en cache
/// pour se repeindre tout de suite au retour, puis se revalide.
class WatchListsProvider extends ChangeNotifier {
  WatchListsProvider(this.apiClient);

  final ApiClient apiClient;

  /// Null tant que le serveur n'a pas dit s'il sait tenir des listes.
  bool? _supported;
  WatchListsOverview? _overview;
  bool _isLoading = false;
  String? _errorMessage;
  int _overviewRequest = 0;

  final Map<int, WatchListDetail> _details = {};
  final Map<int, int> _detailRequests = {};
  final Set<int> _loadingDetails = {};
  final Map<int, String> _detailErrors = {};

  /// Le serveur annonce `watch_lists` : l'onglet et le bouton « Ajouter à
  /// une liste » ne se montrent qu'à cette condition.
  bool get isSupported => _supported == true;
  bool get hasLoaded => _overview != null;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  WatchListsOverview get overview => _overview ?? WatchListsOverview.empty;

  WatchListDetail? detail(int listId) => _details[listId];
  bool isLoadingDetail(int listId) => _loadingDetails.contains(listId);
  String? detailError(int listId) => _detailErrors[listId];

  /// La liste telle que le dernier résumé la connaît, parmi les siennes et
  /// celles des autres.
  WatchList? summary(int listId) {
    for (final list in [...overview.mine, ...overview.shared]) {
      if (list.id == listId) return list;
    }
    return _details[listId]?.list;
  }

  /// Pour les tests d'écran : un serveur qui tient des listes, sans aller le
  /// lui demander.
  @visibleForTesting
  void debugMarkSupported() {
    _supported = true;
    notifyListeners();
  }

  /// Vide les listes du serveur précédent, chargements en cours compris, puis
  /// relit celles du nouveau. Voir [HomeProvider.reset].
  void reset() {
    _overviewRequest++;
    for (final id in _detailRequests.keys.toList()) {
      _detailRequests[id] = _detailRequests[id]! + 1;
    }
    _supported = null;
    _overview = null;
    _isLoading = false;
    _errorMessage = null;
    _details.clear();
    _loadingDetails.clear();
    _detailErrors.clear();
    notifyListeners();
    unawaited(load());
  }

  @override
  void dispose() {
    _overviewRequest++;
    for (final id in _detailRequests.keys.toList()) {
      _detailRequests[id] = _detailRequests[id]! + 1;
    }
    super.dispose();
  }

  /// Relit les listes. [silent] les relit sans montrer de chargement : ce qui
  /// est à l'écran reste jusqu'à la réponse.
  Future<void> load({bool silent = false}) async {
    final request = ++_overviewRequest;
    if (!silent) {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();
    }
    try {
      final supported = await apiClient.supportsWatchLists();
      if (request != _overviewRequest) return;
      _supported = supported;
      _overview = supported
          ? await apiClient.getWatchLists()
          : WatchListsOverview.empty;
      if (request != _overviewRequest) return;
      _errorMessage = null;
    } catch (e) {
      if (request != _overviewRequest) return;
      debugPrint('WatchListsProvider: lists unavailable: $e');
      // Les listes déjà reçues restent affichées : une requête perdue ne doit
      // pas vider la page.
      if (_overview == null || !silent) {
        _errorMessage = tr(
            'Impossible de charger les listes. Vérifiez la connexion au serveur.');
      }
    } finally {
      if (request == _overviewRequest) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// Charge le contenu d'une liste. Le cache se peint d'abord ; [silent] le
  /// revalide sans l'effacer.
  Future<void> loadDetail(int listId, {bool silent = false}) async {
    final request = (_detailRequests[listId] ?? 0) + 1;
    _detailRequests[listId] = request;
    if (!silent || !_details.containsKey(listId)) {
      _loadingDetails.add(listId);
      _detailErrors.remove(listId);
      notifyListeners();
    }
    try {
      final detail = await apiClient.getWatchList(listId);
      if (_detailRequests[listId] != request) return;
      _details[listId] = detail;
      _detailErrors.remove(listId);
    } catch (e) {
      if (_detailRequests[listId] != request) return;
      debugPrint('WatchListsProvider: list $listId unavailable: $e');
      _detailErrors[listId] = tr('Impossible de charger cette liste.');
    } finally {
      if (_detailRequests[listId] == request) {
        _loadingDetails.remove(listId);
        notifyListeners();
      }
    }
  }

  /// Les listes du compte, chacune disant si elle a déjà [title] : ce que
  /// coche la feuille « Ajouter à une liste ».
  Future<List<WatchList>> membership(ListableTitle title) async {
    final overview = await apiClient.getWatchLists(containing: title);
    return overview.mine;
  }

  Future<WatchList> createList({
    required String name,
    String description = '',
    bool isShared = false,
  }) async {
    final list = await apiClient.createWatchList(
        name: name, description: description, isShared: isShared);
    unawaited(load(silent: true));
    return list;
  }

  Future<WatchList> updateList(
    WatchList list, {
    required String name,
    required String description,
    required bool isShared,
  }) async {
    final updated = await apiClient.updateWatchList(list.id,
        name: name, description: description, isShared: isShared);
    final detail = _details[list.id];
    if (detail != null) {
      _details[list.id] = WatchListDetail(list: updated, items: detail.items);
    }
    notifyListeners();
    unawaited(load(silent: true));
    return updated;
  }

  Future<void> deleteList(int listId) async {
    await apiClient.deleteWatchList(listId);
    _details.remove(listId);
    unawaited(load(silent: true));
  }

  /// Range [title] dans une liste. La liste ouverte se relira à son retour à
  /// l'écran.
  Future<WatchListItem> addTitle(int listId, ListableTitle title) async {
    final item = await apiClient.addToWatchList(listId, title);
    if (_details.containsKey(listId)) {
      unawaited(loadDetail(listId, silent: true));
    }
    unawaited(load(silent: true));
    return item;
  }

  /// Retire un titre. Il disparaît de l'écran tout de suite ; s'il n'a pas pu
  /// être retiré, la liste relue le remet.
  Future<void> removeItem(int listId, int itemId) async {
    final detail = _details[listId];
    if (detail != null) {
      _details[listId] = WatchListDetail(
        list: detail.list,
        items: detail.items.where((i) => i.id != itemId).toList(),
      );
      notifyListeners();
    }
    try {
      await apiClient.removeFromWatchList(listId, itemId);
    } finally {
      if (_details.containsKey(listId)) {
        unawaited(loadDetail(listId, silent: true));
      }
      unawaited(load(silent: true));
    }
  }
}
