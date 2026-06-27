import SwiftUI
import AppKit

struct PanelView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    /// When false, the list is laid out without a ScrollView (used by the PNG renderer,
    /// since ImageRenderer can't rasterize ScrollView content).
    var scrollable = true
    @State private var contentHeight: CGFloat = 0

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
        .background(Theme.traySurface)
        .task { if !app.hasScannedOnce { await app.refresh() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 15)).foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 0) {
                Text("Skillui").font(.system(size: 14, weight: .bold))
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if app.updateCount > 0 {
                Button { Task { await app.updateAll() } } label: {
                    Text("Update all").font(.system(size: 11, weight: .semibold))
                }
                .prominentAction().controlSize(.small)
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
            // A ScrollView has no intrinsic height, so in a self-sizing MenuBarExtra(.window)
            // it collapses to zero. Measure the content and size the scroll area to it, capped.
            ScrollView {
                listBody
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                    })
            }
            .frame(height: min(max(contentHeight, 60), Theme.panelMaxHeight))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        } else {
            listBody
        }
    }

    private var listBody: some View {
        VStack(spacing: Theme.Spacing.xl) {
            // The one thing worth your attention leads. When there's nothing to do, a calm
            // affirmation takes its place instead of making you scan the list to be sure.
            if !updatable.isEmpty {
                UpdatesSection(skills: updatable)
            } else if hasTracked {
                CaughtUpBanner()
            }
            ForEach(sections) { sec in
                SectionView(scope: sec.scope, tracked: sec.tracked, untracked: sec.untracked)
            }
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let d = app.lastCheckedAt {
                Text(Self.checkedLabel(d))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let err = app.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9)).foregroundStyle(.yellow).help(err)
            }
            Spacer()
            if app.updateActivity != nil {
                IconButton(systemName: "doc.text", help: "Open update activity") {
                    app.presentUpdateActivityWindow()
                    NSApp.activate(ignoringOtherApps: true)
                    dismiss()
                }
            }
            IconButton(systemName: "macwindow", help: "Open dashboard") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
                dismiss()   // close the menu-bar panel once we've navigated away (HIG)
            }
            IconButton(systemName: "arrow.down.circle", help: "Check for Skillui updates") {
                Task { await app.checkForAppUpdate(manual: true, force: true) }
            }
            IconButton(systemName: "gearshape", help: "Settings") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
                dismiss()
            }
            IconButton(systemName: "power", help: "Quit Skillui") { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    /// "Checked just now" within the last minute (RelativeDateTimeFormatter renders ~now as the
    /// nonsensical "in 0 seconds"), else a relative phrase.
    private static func checkedLabel(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "Checked just now" }
        return "Checked \(relative.localizedString(for: date, relativeTo: Date()))"
    }

    // MARK: Sections

    private struct PanelSection: Identifiable {
        let scope: Scope
        let tracked: [Skill]
        let untracked: [Skill]
        var id: String { scope.rawValue }
    }

    /// Skills with an update ready — surfaced in a single group at the top so the one
    /// actionable thing leads, instead of sitting buried in its scope section below the
    /// up-to-date skills (which is what made you scroll past "nothing to do").
    private var updatable: [Skill] {
        app.visibleSkills
            .filter { app.effectiveStatus(for: $0) == .updateAvailable }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var hasTracked: Bool { app.visibleSkills.contains { $0.isTracked } }

    private var sections: [PanelSection] {
        let updatableIDs = Set(updatable.map(\.id))
        return Scope.allCases.compactMap { scope in
            let inScope = app.visibleSkills.filter { $0.scope == scope && !updatableIDs.contains($0.id) }
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

/// Measures the scroll content's height so the panel can size to it (up to a cap).
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The lead group when anything needs updating: every updatable skill, across scopes, in one
/// card at the top — so the action is the first thing you see, not something you scroll to.
private struct UpdatesSection: View {
    let skills: [Skill]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.amber)
                Text("UPDATES AVAILABLE").font(.system(size: 10, weight: .bold)).tracking(0.5)
                    .foregroundStyle(Theme.amber)
                Text("· \(skills.count)").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(skills.enumerated()), id: \.element.id) { i, s in
                    SkillRowView(skill: s, status: .updateAvailable)
                    if i < skills.count - 1 { Divider().padding(.leading, 12) }
                }
            }
            .cardSurface()
        }
    }
}

/// The calm state: shown in place of the updates group when every tracked skill is current.
private struct CaughtUpBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 14)).foregroundStyle(Theme.statusOK)
            Text("You're all caught up").font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
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
            .cardSurface()
        }
    }
}
