import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/utils/format.dart';

void main() {
  group('formatReleaseDay', () {
    test('écrit la date en toutes lettres, sans préfixe', () {
      expect(formatReleaseDay('2024-03-12'), '12 mars 2024');
      expect(formatReleaseDay('2023-12-01'), '1 déc. 2023');
    });

    test('rend null sans date', () {
      expect(formatReleaseDay(null), isNull);
      expect(formatReleaseDay('  '), isNull);
    });

    test('rend la chaîne brute si elle ne se lit pas', () {
      expect(formatReleaseDay('bientôt'), 'bientôt');
    });
  });

  group('formatAirDate', () {
    final now = DateTime(2026, 9, 24, 15);

    test('distingue passé, aujourd’hui et futur', () {
      expect(formatAirDate('2026-09-01', now: now), 'Sorti le 1 sept. 2026');
      expect(formatAirDate('2026-09-24', now: now), 'Sortie aujourd’hui');
      expect(formatAirDate('2026-10-03', now: now),
          'Sortie prévue le 3 oct. 2026');
    });
  });
}
