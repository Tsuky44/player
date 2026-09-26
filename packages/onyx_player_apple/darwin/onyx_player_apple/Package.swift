// swift-tools-version: 5.9

// Le lecteur d'Onyx sur iPhone et Mac. Le même code sert l'Apple TV par la copie
// de `tvos/`, que `tool/sync_tvos.dart` tient identique.

import PackageDescription

let package = Package(
  name: "onyx_player_apple",
  platforms: [
    // Les planchers d'AetherEngine : SwiftPM refuse de résoudre en dessous.
    .iOS("18.0"),
    .macOS("15.0"),
  ],
  products: [
    .library(name: "onyx-player-apple", targets: ["onyx_player_apple"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
    // Épinglé sur la mineure : le paquet embarque son FFmpeg précompilé, et une
    // mineure qui flotte change le FFmpeg qui tourne sans que rien ne le dise.
    .package(
      url: "https://github.com/superuser404notfound/AetherEngine",
      .upToNextMinor(from: "7.17.0")),
  ],
  targets: [
    .target(
      name: "onyx_player_apple",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
        .product(name: "AetherEngine", package: "AetherEngine"),
      ]
    )
  ]
)
