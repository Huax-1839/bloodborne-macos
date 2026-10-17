// swift-tools-version: 5.10
// SPDX-License-Identifier: GPL-2.0-or-later
// Hunter's Lantern: the macOS launcher (docs/LAUNCHER_PLAN.md). LanternCore holds the logic (no
// UI, unit-tested), HuntersLantern is the SwiftUI app over it; launcher/build.sh assembles the
// .app bundle (no Xcode project).
import PackageDescription

let package = Package(
    name: "HuntersLantern",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LanternCore", targets: ["LanternCore"]),
        .executable(name: "HuntersLantern", targets: ["HuntersLantern"]),
    ],
    targets: [
        .target(name: "LanternCore", resources: [.process("Resources")]),
        .executableTarget(
            name: "HuntersLantern",
            dependencies: ["LanternCore"],
            resources: [.process("Resources")]),
        .testTarget(name: "LanternCoreTests", dependencies: ["LanternCore"]),
    ]
)
