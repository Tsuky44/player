import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/models/models.dart';

Map<String, dynamic> _tier({
  String key = '1080p',
  String label = '1080p · 6 Mbit/s',
  int width = 1920,
  int height = 1080,
  int bitrate = 6160000,
}) =>
    {
      'key': key,
      'label': label,
      'width': width,
      'height': height,
      'bitrate_bps': bitrate,
    };

void main() {
  group('QualityTier', () {
    test('lit ce que le serveur annonce', () {
      final tier = QualityTier.fromJson(_tier());

      expect(tier.key, '1080p');
      expect(tier.label, '1080p · 6 Mbit/s');
      expect(tier.width, 1920);
      expect(tier.height, 1080);
      expect(tier.bitrateBps, 6160000);
    });

    // Le menu pose la résolution en titre et le débit en sous-titre. Le serveur
    // compose le libellé entier pour qu'un débit ne soit écrit qu'à un endroit.
    test('sépare la résolution du débit', () {
      final tier = QualityTier.fromJson(_tier());

      expect(tier.resolutionLabel, '1080p');
      expect(tier.bitrateLabel, '6 Mbit/s');
    });

    test('affiche tel quel un libellé sans séparateur', () {
      final tier = QualityTier.fromJson(_tier(label: 'Automatique'));

      expect(tier.resolutionLabel, 'Automatique');
      expect(tier.bitrateLabel, isNull);
    });

    test('décrit un barreau par sa taille et son débit', () {
      expect(
        QualityTier.fromJson(_tier()).sizeAndBitrateLabel,
        '1920×1080 · 6 Mbit/s',
      );
    });

    // Un serveur qui n'enverrait pas les dimensions ne doit pas produire
    // « 0×0 » dans le menu.
    test('retombe sur le libellé quand la taille manque', () {
      final tier = QualityTier.fromJson(_tier(width: 0, height: 0));

      expect(tier.sizeAndBitrateLabel, '6 Mbit/s');
    });

    test('lit un barreau en kbit/s', () {
      final tier = QualityTier.fromJson(
        _tier(key: '360p-420k', label: '360p · 420 kbit/s', bitrate: 484000),
      );

      expect(tier.resolutionLabel, '360p');
      expect(tier.bitrateLabel, '420 kbit/s');
    });
  });

  group('MediaTracks.qualities', () {
    test('lit l\'échelle dans l\'ordre du serveur', () {
      final tracks = MediaTracks.fromJson({
        'audio': [],
        'subtitles': [],
        'qualities': [
          _tier(key: '1080p', label: '1080p · 6 Mbit/s'),
          _tier(key: '720p', label: '720p · 3,5 Mbit/s', height: 720),
        ],
      });

      expect(tracks.qualities.map((t) => t.key), ['1080p', '720p']);
    });

    // La médiathèque peut réunir plusieurs serveurs (ADR-0013) : un serveur
    // plus ancien ne renvoie rien, et le menu doit retomber sur sa liste figée
    // plutôt que de s'afficher vide.
    test('reste vide quand le serveur ne connaît pas l\'échelle', () {
      final tracks = MediaTracks.fromJson({'audio': [], 'subtitles': []});

      expect(tracks.qualities, isEmpty);
    });

    test('écarte les barreaux inutilisables', () {
      final tracks = MediaTracks.fromJson({
        'audio': [],
        'subtitles': [],
        'qualities': [
          _tier(),
          {'key': '', 'label': 'Sans clé'},
          {'key': 'sans-libelle', 'label': ''},
          'pas un objet',
        ],
      });

      expect(tracks.qualities.map((t) => t.key), ['1080p']);
    });
  });
}
