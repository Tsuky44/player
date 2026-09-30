import 'dart:math' as math;

/// Le découpage d'un fichier en tranches pour la session d'arrière-plan
/// d'iOS (ADR-0040), sans rien toucher du disque ni du réseau.
///
/// Les bornes sont alignées sur des multiples de la taille de tranche, sauf la
/// première, qui part de ce qui est déjà assemblé. C'est ce qui garde les
/// tranches reconnaissables d'une app à l'autre : une tranche arrivée pendant
/// que l'app était fermée porte le même début que celle qu'on redemanderait.
class ChunkRange {
  const ChunkRange(this.start, this.end);

  /// Premier octet de la tranche.
  final int start;

  /// Dernier octet, inclus, comme dans un en-tête `Range:`.
  final int end;

  int get length => end - start + 1;

  @override
  bool operator ==(Object other) =>
      other is ChunkRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'ChunkRange($start-$end)';
}

/// Les tranches qui couvrent `[have, total)`.
List<ChunkRange> chunkRanges({
  required int have,
  required int total,
  required int chunkBytes,
}) {
  final ranges = <ChunkRange>[];
  var start = have;
  while (start < total) {
    final boundary = (start ~/ chunkBytes + 1) * chunkBytes;
    final end = math.min(boundary, total) - 1;
    ranges.add(ChunkRange(start, end));
    start = end + 1;
  }
  return ranges;
}

/// Ce qu'il reste à faire d'un fichier dont [have] octets sont assemblés.
class ChunkPlan {
  const ChunkPlan({
    required this.toFetch,
    required this.stale,
    required this.bytesOnDisk,
  });

  /// Les tranches ni sur le disque ni en cours : à confier au système.
  final List<ChunkRange> toFetch;

  /// Les débuts des tranches sur le disque qui ne correspondent à rien du
  /// plan (mauvaise longueur, ancien découpage) : à effacer.
  final List<int> stale;

  /// Octets des tranches valides, finies mais pas encore assemblées.
  final int bytesOnDisk;
}

/// [onDisk] donne, par début de tranche, la longueur du fichier déposé ;
/// [running] les débuts des tranches que le système est en train de rapatrier.
ChunkPlan planChunks({
  required int have,
  required int total,
  required int chunkBytes,
  required Map<int, int> onDisk,
  required Set<int> running,
}) {
  final ranges = chunkRanges(have: have, total: total, chunkBytes: chunkBytes);
  final lengthOf = {for (final r in ranges) r.start: r.length};
  final stale = <int>[];
  var bytesOnDisk = 0;
  onDisk.forEach((start, length) {
    if (lengthOf[start] == length) {
      bytesOnDisk += length;
    } else {
      stale.add(start);
    }
  });
  stale.sort();
  return ChunkPlan(
    toFetch: [
      for (final r in ranges)
        if (onDisk[r.start] != r.length && !running.contains(r.start)) r,
    ],
    stale: stale,
    bytesOnDisk: bytesOnDisk,
  );
}
