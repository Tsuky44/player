import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/downloads/chunk_plan.dart';

void main() {
  test('les tranches s’alignent sur leur taille, sauf la première', () {
    // Un fichier repris à l'octet 150 : la première tranche finit au premier
    // multiple, les suivantes gardent des débuts reconnaissables d'une app à
    // l'autre.
    expect(chunkRanges(have: 150, total: 1000, chunkBytes: 400), const [
      ChunkRange(150, 399),
      ChunkRange(400, 799),
      ChunkRange(800, 999),
    ]);
    expect(chunkRanges(have: 0, total: 800, chunkBytes: 400), const [
      ChunkRange(0, 399),
      ChunkRange(400, 799),
    ]);
    expect(chunkRanges(have: 1000, total: 1000, chunkBytes: 400), isEmpty);
  });

  test('ne redemande ni ce qui est déposé, ni ce qui court encore', () {
    final plan = planChunks(
      have: 0,
      total: 1000,
      chunkBytes: 400,
      onDisk: {400: 400},
      running: {0},
    );
    expect(plan.toFetch, const [ChunkRange(800, 999)]);
    expect(plan.stale, isEmpty);
    expect(plan.bytesOnDisk, 400);
  });

  test('une tranche de mauvaise longueur est jetée et redemandée', () {
    // Le fichier du serveur a changé, ou un ancien découpage traîne : garder
    // ces octets corromprait l'assemblage.
    final plan = planChunks(
      have: 0,
      total: 1000,
      chunkBytes: 400,
      onDisk: {400: 399, 123: 50},
      running: const {},
    );
    expect(plan.stale, [123, 400]);
    expect(plan.bytesOnDisk, 0);
    expect(plan.toFetch.map((r) => r.start), [0, 400, 800]);
  });
}
