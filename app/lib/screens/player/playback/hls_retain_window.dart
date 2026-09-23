/// La première seconde qu'une session HLS peut encore servir.
///
/// Un serveur qui efface les vieux segments d'une session (voir
/// `retain_seconds`) garde [retainSeconds] derrière le dernier segment que le
/// lecteur lui a demandé — c'est-à-dire derrière la fin de ce qui est en
/// mémoire tampon, [bufferedEnd]. Reculer avant, c'est demander un segment
/// effacé : il faut une nouvelle session.
///
/// La marge couvre l'écart entre ce que le lecteur annonce en tampon et ce
/// qu'il a réellement demandé, qui peut le précéder : mieux vaut rouvrir une
/// session pour rien que tomber sur un segment qui n'existe plus.
int retainedFloorSeconds({
  required int startOffset,
  required int bufferedEnd,
  required int? retainSeconds,
}) {
  const margin = 60;
  if (retainSeconds == null || retainSeconds <= 0) return startOffset;
  final floor = bufferedEnd - retainSeconds + margin;
  return floor > startOffset ? floor : startOffset;
}
