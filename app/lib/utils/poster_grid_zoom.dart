import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Zoom des grilles d'affiches : combien de colonnes on ajoute ou on retire à
/// ce que `AppLayout.posterGridCount` choisit pour la largeur de la fenêtre.
///
/// Un réglage de l'appareil, partagé par tous les écrans en grille (demandes,
/// bibliothèques, collections, listes, recherche) : on règle la densité une
/// fois, Ctrl + molette, et elle vaut partout. On stocke un écart plutôt qu'un
/// nombre de colonnes pour qu'il reste juste quand la fenêtre change de taille.
class PosterGridZoom extends ChangeNotifier {
  PosterGridZoom._();

  static final PosterGridZoom instance = PosterGridZoom._();

  static const String _key = 'poster_grid_zoom_offset';

  /// Bornes du nombre de colonnes effectif. Sous 2, une affiche déborde de
  /// l'écran ; au-delà de 14, elle n'est plus qu'une vignette illisible.
  static const int minColumns = 2;
  static const int maxColumns = 14;

  int _offset = 0;
  int _base = minColumns;
  bool _loaded = false;

  /// Colonnes en plus (positif) ou en moins (négatif) par rapport au choix
  /// automatique.
  int get offset => _offset;

  /// Nombre de colonnes à afficher pour un choix automatique de [base].
  int apply(int base) {
    // Mémorisé pour que [step] borne l'écart d'après la grille réellement
    // affichée, sans quoi la molette tournerait dans le vide à la butée.
    _base = base;
    return (base + _offset).clamp(minColumns, maxColumns);
  }

  /// Lit l'écart enregistré. Idempotent : chaque région de zoom l'appelle.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(_key) ?? 0;
      if (saved != _offset) {
        _offset = saved;
        notifyListeners();
      }
    } catch (_) {
      // Faute de disque, le zoom vaut pour la séance.
    }
  }

  /// Un cran de molette : [columnsDelta] > 0 ajoute des colonnes (affiches
  /// plus petites), < 0 en retire.
  void step(int columnsDelta) {
    final next =
        (_offset + columnsDelta).clamp(minColumns - _base, maxColumns - _base);
    if (next == _offset) return;
    _offset = next;
    notifyListeners();
    _persist();
  }

  void reset() {
    if (_offset == 0) return;
    _offset = 0;
    notifyListeners();
    _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_key, _offset);
    } catch (_) {
      // Faute de disque, le zoom vaut pour la séance.
    }
  }

  @visibleForTesting
  void resetForTest() {
    _offset = 0;
    _base = minColumns;
    _loaded = false;
  }
}

/// Rend le zoom observable depuis un `SliverLayoutBuilder` : celui qui lit
/// [PosterGridZoomScope.watch] dans son builder est reconstruit quand le zoom
/// change, sans que l'écran qui le contient ait à se reconstruire.
class PosterGridZoomScope extends InheritedNotifier<PosterGridZoom> {
  const PosterGridZoomScope({
    super.key,
    required PosterGridZoom zoom,
    required super.child,
  }) : super(notifier: zoom);

  /// Zoom courant, et abonnement à ses changements quand une région de zoom
  /// englobe [context]. Hors d'une région, le zoom enregistré vaut quand même.
  static PosterGridZoom watch(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<PosterGridZoomScope>();
    return scope?.notifier ?? PosterGridZoom.instance;
  }
}
