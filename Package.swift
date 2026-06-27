// swift-tools-version: 6.0
import PackageDescription

// Quiver — menu-bar manager for skills.sh-installed agent skills.
// No third-party dependencies: system frameworks only (SwiftUI, AppKit, ServiceManagement).
// Built as an SPM executable, then assembled into a .app bundle by scripts/build-app.sh
// (the bundle is what makes MenuBarExtra + SMAppService behave correctly).
let package = Package(
    name: "Quiver",
    platforms: [.macOS("26.0")],   // Liquid Glass baseline — Tahoe or newer
    targets: [
        .executableTarget(
            name: "Quiver",
            path: "Sources/Quiver",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "QuiverTests",
            dependencies: ["Quiver"],
            path: "Tests/QuiverTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
