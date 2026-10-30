import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Zoom des grilles d'affiches : combien de colonnes on ajoute ou on retire à
/// ce que `AppLayout.posterGridCount` choisit pour la largeur de la fenêtre.
///
/// Un réglage de l'appareil, partagé par tous les écrans en grille (demandes,
/// bibliothèques, collections, listes, recherche) : on règle la densité une
/// fois, par Ctrl + molette ou par le curseur de `PosterGridZoomSlider`, et
/// elle vaut partout. On stocke un écart plutôt qu'un nombre de colonnes pour
/// qu'il reste juste quand la fenêtre change de taille.
///
/// L'écart est commun à toute l'application ; le choix automatique d'où il
/// part ne l'est pas. Chaque `PosterGridZoomRegion` a donc sa propre instance,
/// qui retient la base de sa grille : sans cela, deux pages empilées de
/// largeurs différentes se la disputeraient à chaque image.
class PosterGridZoom extends ChangeNotifier {
  PosterGridZoom() {
    _shared.addListener(notifyListeners);
  }

  /// Le zoom d'une grille hors de toute région : l'écart enregistré vaut
  /// quand même.
  static final PosterGridZoom instance = PosterGridZoom();

  static const String _key = 'poster_grid_zoom_offset';

  /// Bornes du nombre de colonnes effectif. Sous 2, une affiche déborde de
  /// l'écran ; au-delà de 14, elle n'est plus qu'une vignette illisible.
  static const int minColumns = 2;
  static const int maxColumns = 14;

  static final ValueNotifier<int> _shared = ValueNotifier<int>(0);
  static bool _loaded = false;

  int _base = minColumns;
  bool _baseNotifyQueued = false;
  bool _disposed = false;

  /// Colonnes en plus (positif) ou en moins (négatif) par rapport au choix
  /// automatique.
  int get offset => _shared.value;

  /// Nombre de colonnes affichées pour la dernière base reçue de la grille.
  int get columns => (_base + offset).clamp(minColumns, maxColumns);

  /// Nombre de colonnes à afficher pour un choix automatique de [base].
  int apply(int base) {
    // Mémorisée pour que [setColumns] et [step] bornent l'écart d'après la
    // grille réellement affichée, sans quoi la molette tournerait dans le vide
    // à la butée. L'appel a lieu en pleine mise en page : ceux qui lisent
    // [columns] (le curseur) sont prévenus à l'image suivante.
    if (base != _base) {
      _base = base;
      _notifyAfterLayout();
    }
    return columns;
  }

  void _notifyAfterLayout() {
    if (_baseNotifyQueued) return;
    _baseNotifyQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _baseNotifyQueued = false;
      if (!_disposed) notifyListeners();
    });
  }

  /// Lit l'écart enregistré. Idempotent : chaque région de zoom l'appelle.
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _shared.value = prefs.getInt(_key) ?? 0;
    } catch (_) {
      // Faute de disque, le zoom vaut pour la séance.
    }
  }

  /// Un cran de molette : [columnsDelta] > 0 ajoute des colonnes (affiches
  /// plus petites), < 0 en retire.
  void step(int columnsDelta) => _setOffset(offset + columnsDelta);

  /// Fixe le nombre de colonnes affichées, dans les bornes.
  void setColumns(int columns) => _setOffset(columns - _base);

  void reset() => _setOffset(0);

  void _setOffset(int value) {
    final next = value.clamp(minColumns - _base, maxColumns - _base);
    if (next == offset) return;
    _shared.value = next;
    _persist();
  }

  static Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_key, _shared.value);
    } catch (_) {
      // Faute de disque, le zoom vaut pour la séance.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _shared.removeListener(notifyListeners);
    super.dispose();
  }

  @visibleForTesting
  void resetForTest() {
    _shared.value = 0;
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

  /// Zoom de la région qui englobe [context], et abonnement à ses
  /// changements. Hors d'une région, le zoom enregistré vaut quand même.
  static PosterGridZoom watch(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<PosterGridZoomScope>();
    return scope?.notifier ?? PosterGridZoom.instance;
  }
}
