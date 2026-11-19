// swift-tools-version: 5.9
//
// Anime4KPlayer: Anime4K upscaling for the vlc-ios fork.
// All of our code lives in this package so VLC's own project needs only a
// package reference plus a few hook points.

import PackageDescription

let package = Package(
    name: "Anime4KPlayer",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(name: "Anime4KPlayer", targets: ["Anime4KPlayer"]),
    ],
    targets: [
        // Vendored from imxieyi/Anime4KMetal (Apache-2.0) + bloc97/Anime4K GLSL (MIT).
        // See VENDORED.md for the upstream commits and local modifications.
        .target(
            name: "Anime4KMetalCore",
            resources: [
                .copy("Resources/glsl"),
            ]
        ),
        // Our code: frame hook, ingest, pipeline, settings, controls.
        .target(
            name: "Anime4KPlayer",
            dependencies: ["Anime4KMetalCore"]
        ),
        .testTarget(
            name: "Anime4KPlayerTests",
            dependencies: ["Anime4KPlayer", "Anime4KMetalCore"]
        ),
        .testTarget(
            name: "Anime4KMetalCoreTests",
            dependencies: ["Anime4KMetalCore"]
        ),
    ]
)
