// swift-tools-version: 5.9

// Le lecteur d'Onyx sur Apple TV. flutter-tvos ne lit que `tvos/Package.swift` ;
// les sources sont une copie de `darwin/`, que `tool/sync_tvos.dart` écrit et
// qu'un test de l'app garde identique. Ne rien modifier ici à la main.

import PackageDescription

let package = Package(
  name: "onyx_player_apple",
  platforms: [
    // Le plancher d'AetherEngine : SwiftPM refuse de résoudre en dessous.
    .tvOS("18.0")
  ],
  products: [
    .library(name: "onyx-player-apple", targets: ["onyx_player_apple"])
  ],
  dependencies: [
    // Généré par flutter-tvos à côté de ce paquet, comme pour iOS et macOS.
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
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
