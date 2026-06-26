import SwiftUI
import AppKit

struct PanelView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openSettings) private var openSettings
    /// When false, the list is laid out without a ScrollView (used by the PNG renderer,
    /// since ImageRenderer can't rasterize ScrollView content).
    var scrollable = true

    private var busy: Bool { app.isScanning || app.isCheckingUpdates }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: Theme.panelWidth)
        .frame(maxHeight: scrollable ? Theme.panelMaxHeight : nil)
        .task { if !app.hasScannedOnce { await app.refresh() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 15)).foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 0) {
                Text("Quiver").font(.system(size: 14, weight: .bold))
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if app.updateCount > 0 {
                Button { Task { await app.updateAll() } } label: {
                    Text("Update all").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent).tint(Theme.amber).controlSize(.small)
                .help("Update all \(app.updateCount) skills")
            }
            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 22, height: 22)
            } else {
                IconButton(systemName: "arrow.clockwise", help: "Refresh") {
                    Task { await app.refresh(force: true) }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var subtitle: String {
        if app.cliMissing { return "skills CLI not found" }
        if app.isScanning && !app.hasScannedOnce { return "Scanning…" }
        let n = app.updateCount
        let total = app.skills.count
        if n > 0 { return "\(total) skills · \(n) update\(n == 1 ? "" : "s") available" }
        return "\(total) skills · up to date"
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if app.cliMissing {
            StateMessage(icon: "terminal",
                         title: "skills CLI not found",
                         subtitle: "Install Node, or set the npx / skills path in Settings.")
        } else if !app.hasScannedOnce && app.isScanning {
            VStack(spacing: 8) {
                ProgressView()
                Text("Scanning skills…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 54)
        } else if app.skills.isEmpty {
            StateMessage(icon: "tray",
                         title: "No skills installed",
                         subtitle: "Add one with  npx skills add <owner/repo>")
        } else if scrollable {
            ScrollView { listBody }
        } else {
            listBody
        }
    }

    private var listBody: some View {
        LazyVStack(spacing: 14) {
            ForEach(sections) { sec in
                SectionView(scope: sec.scope, tracked: sec.tracked, untracked: sec.untracked)
            }
        }
        .padding(12)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let d = app.lastCheckedAt {
                Text("Checked \(Self.relative.localizedString(for: d, relativeTo: Date()))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let err = app.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9)).foregroundStyle(.yellow).help(err)
            }
            Spacer()
            IconButton(systemName: "gearshape", help: "Settings") { openSettings() }
            IconButton(systemName: "power", help: "Quit Quiver") { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    // MARK: Sections

    private struct PanelSection: Identifiable {
        let scope: Scope
        let tracked: [Skill]
        let untracked: [Skill]
        var id: String { scope.rawValue }
    }

    private var sections: [PanelSection] {
        Scope.allCases.compactMap { scope in
            let inScope = app.skills.filter { $0.scope == scope }
            guard !inScope.isEmpty else { return nil }
            let tracked = inScope.filter { $0.isTracked }.sorted { rank($0) < rank($1) }
            let untracked = inScope.filter { !$0.isTracked }
            return PanelSection(scope: scope, tracked: tracked, untracked: untracked)
        }
    }

    private func rank(_ s: Skill) -> Int {
        switch app.statuses[s.id] {
        case .updateAvailable: return 0
        case .checking: return 1
        case .upToDate: return 2
        default: return 3
        }
    }
}

/// One scope group: a titled card with tracked rows + a collapsible "Untracked" list.
private struct SectionView: View {
    let scope: Scope
    let tracked: [Skill]
    let untracked: [Skill]
    @Environment(AppState.self) private var app
    @State private var showUntracked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(scope.label.uppercased())
                .font(.system(size: 10, weight: .bold)).tracking(0.5)
                .foregroundStyle(.secondary).padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(tracked.enumerated()), id: \.element.id) { i, s in
                    SkillRowView(skill: s, status: app.statuses[s.id] ?? .unknown)
                    if i < tracked.count - 1 || !untracked.isEmpty {
                        Divider().padding(.leading, 12)
                    }
                }
                if !untracked.isEmpty {
                    DisclosureGroup(isExpanded: $showUntracked) {
                        VStack(spacing: 0) {
                            ForEach(Array(untracked.enumerated()), id: \.element.id) { i, s in
                                SkillRowView(skill: s, status: .unsupported)
                                if i < untracked.count - 1 { Divider().padding(.leading, 12) }
                            }
                        }
                        .padding(.top, 2)
                    } label: {
                        Text("Untracked · \(untracked.count)")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                }
            }
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
        }
    }
}
