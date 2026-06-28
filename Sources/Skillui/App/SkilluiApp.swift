import SwiftUI
import AppKit

@main
struct SkilluiApp: App {
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
                .environment(app)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(app)
        }

        Window("Skillui Dashboard", id: "dashboard") {
            DashboardView()
                .environment(app)
        }
        .defaultSize(width: 980, height: 580)
        .commands { appCommands }

        Window("Software Update", id: "app-update") {
            AppUpdateView()
                .environment(app)
        }
        .defaultSize(width: 560, height: 460)

        Window("Update Activity", id: "update-activity") {
            UpdateActivityView()
                .environment(app)
        }
        .defaultSize(width: 780, height: 520)
    }

    @CommandsBuilder private var appCommands: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates...") {
                Task { await app.checkForAppUpdate(manual: true, force: true) }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(app.isCheckingAppUpdate)
        }
    }
}

/// Menu-bar label: icon + live update-count badge. Also the launch point for the
/// `--dashboard` dev flag (opens the dashboard window on first appearance).
private struct MenuBarLabel: View {
    let count: Int
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "puzzlepiece.extension.fill")
        if count > 0 { Text("\(count)") }
        Color.clear.frame(width: 0, height: 0)
            // Open the window — its own .onAppear flips activation to .regular via AppState's
            // refcount (so .accessory is restored only when the LAST regular window closes, no
            // per-scene races). Still activate here: re-triggering an already-open window won't
            // refire onAppear, so this is what foregrounds it (e.g. a background update bumps the
            // revision while the window sits behind another app). Double-activate on first open is
            // harmless and leaves the refcount untouched.
            .onAppear {
                app.scheduleInitialAppUpdateCheck()
                if CommandLine.arguments.contains("--dashboard") {
                    openWindow(id: "dashboard")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
            .onChange(of: app.appUpdateWindowRevision) {
                if app.appUpdateWindowRevision > 0 {
                    openWindow(id: "app-update")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
            .onChange(of: app.updateActivityWindowRevision) {
                if app.updateActivityWindowRevision > 0 {
                    openWindow(id: "update-activity")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
    }
}
