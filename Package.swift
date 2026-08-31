// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chrono",
    platforms: [
        // ChronoCore is shared with the iOS remote, so it must stay buildable for both.
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ChronoCore", targets: ["ChronoCore"]),
        .executable(name: "ChronoApp", targets: ["ChronoApp"]),
    ],
    targets: [
        // Pure logic: models, the tracking engine, the Jira client, the remote-control
        // protocol and persistence. No AppKit, no UIKit — this is the layer the iOS app
        // links against, the layer the tests cover, and the layer a future Windows port
        // would be transliterated from.
        .target(
            name: "ChronoCore",
            path: "Sources/ChronoCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The macOS menu bar app: AppKit status item + SwiftUI panels + the platform
        // sensors (idle, mic/camera in use, frontmost app, sleep/lock).
        .executableTarget(
            name: "ChronoApp",
            dependencies: ["ChronoCore"],
            path: "Sources/ChronoApp",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "GenerateIcons",
            path: "Tools/GenerateIcons",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ChronoCoreTests",
            dependencies: ["ChronoCore"],
            path: "Tests/ChronoCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
