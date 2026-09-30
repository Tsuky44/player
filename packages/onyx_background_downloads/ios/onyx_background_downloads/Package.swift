// swift-tools-version: 5.9

// La session de téléchargement d'arrière-plan d'Onyx sur iPhone (ADR-0040).

import PackageDescription

let package = Package(
  name: "onyx_background_downloads",
  platforms: [
    // `NSLock.withLock` ; l'app, elle, exige iOS 18 (AetherEngine).
    .iOS("16.0")
  ],
  products: [
    .library(name: "onyx-background-downloads", targets: ["onyx_background_downloads"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    .target(
      name: "onyx_background_downloads",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework")
      ]
    )
  ]
)
