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
            MenuBarLabel(count: app.updateCount)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(app)
        }

        Window("Quiver Dashboard", id: "dashboard") {
            DashboardView()
                .environment(app)
        }
        .defaultSize(width: 980, height: 580)
    }
}

/// Menu-bar label: icon + live update-count badge. Also the launch point for the
/// `--dashboard` dev flag (opens the dashboard window on first appearance).
private struct MenuBarLabel: View {
    let count: Int
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "puzzlepiece.extension.fill")
        if count > 0 { Text("\(count)") }
        Color.clear.frame(width: 0, height: 0).onAppear {
            if CommandLine.arguments.contains("--dashboard") {
                NSApplication.shared.setActivationPolicy(.regular)
                openWindow(id: "dashboard")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }
}
