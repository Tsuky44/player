/// L'échelle typographique : les seules tailles de texte de l'app.
///
/// Il y en avait 26, dont cinq demi-tailles (10,5, 11,5, 12,5, 13,5, 14,5),
/// décidées site par site : rien ne choquait isolément, mais deux écrans
/// n'avaient jamais exactement la même voix (design-plans/audit-fluidite.md,
/// finding 8). Treize marches, plus serrées en bas — où l'œil distingue un
/// pixel — et plus espacées en haut, sur le modèle des styles de texte
/// d'Apple.
///
/// Une taille littérale dans `lib/` est refusée par
/// `test/app_type_scale_test.dart` : une taille qui manque s'ajoute ici, avec
/// son rôle, avant d'être utilisée.
abstract final class AppType {
  /// Badges de jaquette, compteurs, mentions techniques.
  static const double micro = 10;

  /// Légendes, libellés d'onglets, horodatages.
  static const double caption = 11;

  /// Métadonnées secondaires, sous-titres de carte.
  static const double footnote = 12;

  /// Lignes de liste, boutons compacts, champs du header.
  static const double subhead = 13;

  /// Texte courant.
  static const double body = 14;

  /// Texte courant mis en avant, synopsis.
  static const double callout = 15;

  /// Titres de ligne et de carte.
  static const double headline = 17;

  /// Titres de section.
  static const double title3 = 20;

  /// Titres de panneau, de feuille.
  static const double title2 = 22;

  /// Titres de page compacts.
  static const double title1 = 24;

  /// Titres de fiche.
  static const double display = 28;

  /// Grands titres de page (réglages, demandes).
  static const double largeTitle = 34;

  /// Titres en surimpression sur une image plein écran.
  static const double hero = 40;

  /// Toutes les marches, dans l'ordre.
  static const List<double> scale = [
    micro,
    caption,
    footnote,
    subhead,
    body,
    callout,
    headline,
    title3,
    title2,
    title1,
    display,
    largeTitle,
    hero,
  ];
}
