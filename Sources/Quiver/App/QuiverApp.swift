import SwiftUI
import AppKit

@main
struct QuiverApp: App {
    @State private var app = AppState()

    init() {
        // Dev verification hooks (run headless + exit when their args are present).
        DebugCLI.runIfRequested()      // --scan-dump [--check]
        RenderCLI.runIfRequested()     // --render-png <path>
        // Menu-bar-only. Belt-and-suspenders with Info.plist LSUIElement=YES so the
        // app also stays out of the Dock when launched as a bare binary during dev.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(app)
        } label: {
            // Icon + a live count badge when updates are available (glanceable — the
            // whole point of the app). Idea adapted from OpenUsage's menu-bar readout.
            Image(systemName: "puzzlepiece.extension.fill")
            if app.updateCount > 0 {
                Text("\(app.updateCount)")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
