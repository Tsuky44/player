import '../../../models/models.dart';
import '../../../services/playback_preferences_storage.dart';
import 'playback_session.dart';

/// La piste audio du moteur qui correspond à celle que le serveur numérote.
///
/// Le client choisit une piste par son rang dans la liste du serveur, qui suit
/// le conteneur. Le moteur d'un téléviseur LG liste celles du fichier dans
/// l'ordre de son pipeline, que rien ne garantit identique : le rang seul
/// donnait alors l'anglais à qui avait demandé le français. Quand les deux
/// listes disent la langue de chaque piste, c'est donc elle qui désigne — le
/// rang parmi les pistes de la même langue départage un film à deux pistes
/// françaises. Sans langue lisible ou si les comptes divergent (un codec que le
/// moteur ignore), on retombe sur le rang dans la liste, comme avant.
PlaybackTrack? engineAudioTrackFor(
  int index,
  List<MediaAudioTrack> canonical,
  List<PlaybackTrack> engine,
) {
  if (engine.isEmpty || index < 0 || index >= canonical.length) return null;

  final language = _language(canonical[index].language);
  if (language != null) {
    final sameInCatalogue = [
      for (var i = 0; i < canonical.length; i++)
        if (_language(canonical[i].language) == language) i,
    ];
    final sameInEngine = [
      for (final track in engine)
        if (_language(track.language) == language) track,
    ];
    if (sameInEngine.length == sameInCatalogue.length) {
      return sameInEngine[sameInCatalogue.indexOf(index)];
    }
  }
  return engine[index.clamp(0, engine.length - 1)];
}

String? _language(String? code) =>
    PlaybackPreferencesStorage.normalizeLangCode(code);
