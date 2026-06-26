import SwiftUI
import AppKit

@main
struct QuiverApp: App {
    @State private var app = AppState()

    init() {
        // Menu-bar-only. Belt-and-suspenders with Info.plist LSUIElement=YES so the
        // app also stays out of the Dock when launched as a bare binary during dev.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Quiver", systemImage: "puzzlepiece.extension.fill") {
            PanelView()
                .environment(app)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
