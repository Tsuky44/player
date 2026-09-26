import AetherEngine
import CoreGraphics
import Foundation
import ImageIO

#if os(macOS)
  import FlutterMacOS
#else
  import Flutter
#endif

/// Les répliques à l'écran, et seulement quand elles changent.
///
/// AetherEngine publie toutes les répliques décodées autour de la tête de
/// lecture, datées en temps source ; c'est à l'hôte de choisir celles qui
/// couvrent l'image affichée. L'horloge avance dix fois par seconde, mais une
/// réplique tient plusieurs secondes : on ne prévient Dart qu'au changement.
struct ActiveCues {
  private(set) var ids: [Int] = []

  /// Les répliques actives à [time], ou nil si ce sont les mêmes qu'avant.
  mutating func update(_ cues: [SubtitleCue], at time: Double) -> [SubtitleCue]? {
    let active = cues.filter { $0.startTime <= time && time < $0.endTime }
    let activeIds = active.map(\.id)
    guard activeIds != ids else { return nil }
    ids = activeIds
    return active
  }

  mutating func reset() {
    ids = []
  }
}

enum SubtitleFrames {
  /// Le cadre prêt à partir vers Dart.
  ///
  /// [canvas] est la taille de l'image vidéo, qui sert quand le PGS ne dit pas
  /// la sienne : sans l'une ni l'autre, un bitmap ne peut pas être placé, et
  /// il est écarté plutôt que posé au hasard.
  static func frame(playerId: Int64, cues: [SubtitleCue], canvas: CGSize) -> OnyxAppleSubtitleFrame {
    var lines: [String] = []
    var bitmaps: [OnyxAppleSubtitleBitmap] = []
    for cue in cues {
      switch cue.body {
      case .text, .richText:
        if let text = cue.text, !text.isEmpty { lines.append(text) }
      case .image(let image):
        if let bitmap = bitmap(image, fallbackCanvas: canvas) { bitmaps.append(bitmap) }
      }
    }
    return OnyxAppleSubtitleFrame(playerId: playerId, lines: lines, bitmaps: bitmaps)
  }

  /// Un sous-titre image, placé en fractions du canevas (origine en haut à
  /// gauche, comme le PGS).
  private static func bitmap(_ image: SubtitleImage, fallbackCanvas: CGSize) -> OnyxAppleSubtitleBitmap? {
    let canvas = image.canvasSize.width > 0 && image.canvasSize.height > 0 ? image.canvasSize : fallbackCanvas
    guard canvas.width > 0, canvas.height > 0, let png = png(image.cgImage) else { return nil }
    return OnyxAppleSubtitleBitmap(
      png: FlutterStandardTypedData(bytes: png),
      left: image.position.minX / canvas.width,
      top: image.position.minY / canvas.height,
      width: image.position.width / canvas.width,
      height: image.position.height / canvas.height)
  }

  private static func png(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }
}
