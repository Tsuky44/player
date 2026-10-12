/// L'épisode suivant n'existe pas dans la langue qu'on suit : un anime sorti en
/// VOSTFR dont la VF n'arrive que des semaines plus tard (ADR-0057).
///
/// Le lecteur ne passe alors pas à la suite de lui-même : il demande si l'on
/// veut continuer dans une autre langue ou attendre la sienne.
class AudioLanguageGap {
  /// La langue qu'on suit et que l'épisode suivant n'a pas.
  final String wanted;

  /// Celle qu'on entendrait à la place : la piste par défaut de cet épisode.
  final String offered;

  const AudioLanguageGap({required this.wanted, required this.offered});

  /// Ce qui manque à un épisode dont les langues audio sont [next], ou null
  /// quand il n'y a rien à demander.
  ///
  /// [heard] est la langue de la piste en cours, [wanted] celle qu'on a héritée
  /// sans la trouver dans cet épisode-ci. L'une ou l'autre suffit : qui a
  /// accepté de continuer en japonais n'est pas réinterrogé à chaque épisode,
  /// et retrouve le français sans question dès qu'un épisode l'a.
  ///
  /// Une liste vide veut dire que le serveur ne sait pas — fichier pas encore
  /// sondé, serveur plus ancien, pistes sans langue : on n'affirme alors rien.
  static AudioLanguageGap? between({
    required String? heard,
    required String? wanted,
    required List<String> next,
  }) {
    if (next.isEmpty) return null;
    final followed = wanted ?? heard;
    if (followed == null) return null;
    if (next.contains(followed) || (heard != null && next.contains(heard))) {
      return null;
    }
    return AudioLanguageGap(wanted: followed, offered: next.first);
  }

  /// Ce qui manque à l'épisode qu'on vient de lancer, dont les langues audio
  /// sont [available] : la langue suivie [wanted] n'y est pas, et c'est
  /// [heard] qu'on entend à la place.
  static AudioLanguageGap? missing({
    required String? wanted,
    required String? heard,
    required List<String> available,
  }) {
    if (wanted == null || available.isEmpty) return null;
    if (available.contains(wanted)) return null;
    return AudioLanguageGap(wanted: wanted, offered: heard ?? available.first);
  }
}
