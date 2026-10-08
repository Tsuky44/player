/// Part d'un média à partir de laquelle il compte comme vu. Miroir de
/// `watchedThresholdPercent` côté serveur (`progress.go`), qui tranche ; cette
/// copie ne sert qu'à l'affichage optimiste et au hors ligne.
const double watchedThresholdPercent = 90.0;

/// En dessous, un générique annoncé est tenu pour une fausse détection et ne
/// décide de rien. Miroir de `creditsFloorPercent` côté serveur.
const double creditsFloorPercent = 70.0;

/// Dit si une lecture quittée à [positionSeconds] a vu le média.
///
/// [leftDuringCredits] : la lecture s'est arrêtée dans le générique de fin.
/// Le seuil seul ne suffit pas là : un épisode d'animé de 24 min dont le
/// générique et l'aperçu du suivant durent 3 min 30 entre dans son générique à
/// 85 %, et l'enchaînement automatique le quitte cinq secondes plus tard. Il
/// restait alors « en cours » alors que tout l'épisode avait été regardé.
///
/// Le serveur applique la même règle aux génériques qu'il a détectés ; celle
/// d'ici couvre ceux que seul le lecteur connaît (chapitres du fichier). Elle
/// garde un plancher, [creditsFloorPercent] : un marqueur posé à tort au
/// milieu de l'épisode ne doit pas faire perdre la reprise.
bool countsAsWatched({
  required int positionSeconds,
  required int durationSeconds,
  bool leftDuringCredits = false,
}) {
  if (positionSeconds <= 0 || durationSeconds <= 0) return false;
  final percent = positionSeconds / durationSeconds * 100;
  if (leftDuringCredits && percent >= creditsFloorPercent) return true;
  return percent >= watchedThresholdPercent;
}
