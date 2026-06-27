// swift-tools-version: 6.0
import PackageDescription

// Skillui — menu-bar manager for skills.sh-installed agent skills.
// No third-party dependencies: system frameworks only (SwiftUI, AppKit, ServiceManagement).
// Built as an SPM executable, then assembled into a .app bundle by scripts/build-app.sh
// (the bundle is what makes MenuBarExtra + SMAppService behave correctly).
let package = Package(
    name: "Skillui",
    platforms: [.macOS("26.0")],   // Liquid Glass baseline — Tahoe or newer
    targets: [
        .executableTarget(
            name: "Skillui",
            path: "Sources/Skillui",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SkilluiTests",
            dependencies: ["Skillui"],
            path: "Tests/SkilluiTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
