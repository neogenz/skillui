import SwiftUI
import AppKit

struct AppUpdateView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var activateOnAppear = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 460)
        .background(Theme.traySurface)
        .onAppear { if activateOnAppear { app.enterRegularActivation() } }
        .onDisappear { if activateOnAppear { app.leaveRegularActivation() } }
    }

    /// Decoded once, not on every body re-evaluation (the view rebuilds on each app-update state
    /// transition / download toggle).
    private static let cachedAppIcon: NSImage? =
        Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))

    private var header: some View {
        HStack(spacing: 12) {
            appIcon
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
    }

    @ViewBuilder private var appIcon: some View {
        if let image = Self.cachedAppIcon {
            Image(nsImage: image)
                .resizable()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Theme.amber)
                .frame(width: 46, height: 46)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var title: String {
        switch app.appUpdateResult {
        case .checking: return "Checking for updates"
        case .available(let release): return "Skillui \(release.version) is available"
        case .upToDate: return "Skillui is up to date"
        case .failed: return "Update check failed"
        case nil: return "Software Update"
        }
    }

    private var subtitle: String {
        switch app.appUpdateResult {
        case .checking: return "Contacting GitHub Releases..."
        case .available(let release): return "\(release.assetName) · \(release.sizeLabel)"
        case .upToDate(let version): return "Current version: \(version)"
        case .failed(let message): return message
        case nil: return "Use Check for Updates to look for a new release."
        }
    }

    @ViewBuilder private var content: some View {
        switch app.appUpdateResult {
        case .checking:
            VStack(spacing: 10) {
                ProgressView()
                Text("Checking GitHub Releases...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .available(let release):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Release Notes").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let url = release.htmlURL {
                        Button("View on GitHub") { NSWorkspace.shared.open(url) }
                            .controlSize(.small)
                    }
                }
                ScrollView {
                    Text(release.body.isEmpty ? "No release notes were published for this version." : release.body)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            }
            .padding(18)

        case .upToDate:
            StateMessage(icon: "checkmark.seal", title: "No update available",
                         subtitle: "You're running the latest published release.")

        case .failed(let message):
            StateMessage(icon: "exclamationmark.triangle", title: "Couldn't check for updates",
                         subtitle: message)

        case nil:
            StateMessage(icon: "arrow.down.circle", title: "Software Update",
                         subtitle: "Check GitHub Releases for a newer Skillui DMG.")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let release = app.availableAppRelease, let url = release.htmlURL {
                Button("Open Release") { NSWorkspace.shared.open(url) }
            }
            Spacer()
            Button("Check Again") { Task { await app.checkForAppUpdate(manual: true, force: true) } }
                .disabled(app.isCheckingAppUpdate || app.isDownloadingAppUpdate)
            if app.availableAppRelease != nil {
                Button("Skip for Now") {
                    app.dismissAppUpdateForNow()
                    dismiss()
                }
                .disabled(app.isDownloadingAppUpdate)
            } else {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if let release = app.availableAppRelease {
                Button {
                    Task { await app.downloadAndOpenAppUpdate(release) }
                } label: {
                    if app.isDownloadingAppUpdate {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Download DMG")
                    }
                }
                .prominentAction()
                .keyboardShortcut(.defaultAction)
                .disabled(app.isDownloadingAppUpdate || release.assetDownloadURL == nil)
            }
        }
        .padding(18)
    }
}
