import SwiftUI
import AppKit

/// Full-window dashboard: every skill across global + all discovered projects, with the
/// project-local vs symlinked-into-global distinction front and center. Sortable, filterable,
/// worktrees grouped under their main repo.
struct DashboardView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openSettings) private var openSettings

    @State private var search = ""
    @State private var scopeFilter: ScopeFilter = .all
    @State private var linkFilter: LinkFilter = .all
    @State private var projectFilter: String? = nil
    @State private var updatesOnly = false
    @State private var sortOrder = [KeyPathComparator(\Skill.name)]

    enum ScopeFilter: String, CaseIterable { case all = "All", global = "Global", project = "Project" }
    enum LinkFilter: String, CaseIterable { case all = "All links", local = "Local", linked = "Linked", external = "External", global = "Global" }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if app.isRateLimited && app.githubPAT.isEmpty { rateLimitBanner }
            Divider()
            table
        }
        .frame(minWidth: 900, minHeight: 460)
        .task { if app.projectScanSkills.isEmpty { await app.scanProjects() } }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: Toolbar

    private var projectGroups: [String] {
        Array(Set(app.dashboardSkills.compactMap { $0.projectGroup })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { Task { await app.rescanProjects() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(app.isScanningProjects)
            if app.isScanningProjects { ProgressView().controlSize(.small) }

            Text("\(app.discoveredProjects.count) projects · \(rows.count) skills")
                .font(.callout).foregroundStyle(.secondary)

            rootChip
            Spacer()

            Picker("", selection: $projectFilter) {
                Text("All projects").tag(String?.none)
                ForEach(projectGroups, id: \.self) { Text($0).tag(String?($0)) }
            }
            .pickerStyle(.menu).fixedSize().help("Filter by project / repo (worktrees included)")

            Picker("", selection: $scopeFilter) {
                ForEach(ScopeFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).fixedSize()

            Picker("", selection: $linkFilter) {
                ForEach(LinkFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.fixedSize()

            Toggle("Updates", isOn: $updatesOnly).toggleStyle(.button)
            TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 140)
        }
        .padding(10)
    }

    private var rateLimitBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.statusWarn)
            Text("GitHub rate limit reached — update checks are incomplete. Add a personal access token (5000 req/hr) to finish.")
                .font(.system(size: 11))
            Spacer()
            Button("Add token") { app.requestPATFocus = true; openSettings() }.controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.statusWarn.opacity(0.12))
    }

    private var rootChip: some View {
        let root = app.scanRoot.isEmpty ? "Dev folders" : (app.scanRoot as NSString).abbreviatingWithTildeInPath
        return Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Scan here"
            if panel.runModal() == .OK, let url = panel.url {
                app.scanRoot = url.path
                Task { await app.rescanProjects() }
            }
        } label: {
            Label(root, systemImage: "folder").font(.caption).lineLimit(1)
        }
        .help("Change the scan root")
    }

    // MARK: Rows

    private var rows: [Skill] {
        var r = app.dashboardSkills
        if !search.isEmpty {
            r = r.filter {
                $0.name.localizedCaseInsensitiveContains(search)
                    || ($0.source?.localizedCaseInsensitiveContains(search) ?? false)
                    || ($0.projectLabel?.localizedCaseInsensitiveContains(search) ?? false)
            }
        }
        switch scopeFilter {
        case .global: r = r.filter { $0.scope == .global }
        case .project: r = r.filter { $0.scope == .project }
        case .all: break
        }
        switch linkFilter {
        case .local: r = r.filter { $0.linkType == .projectLocal }
        case .linked: r = r.filter { $0.linkType == .linkedGlobal }
        case .external: r = r.filter { $0.linkType == .linkedExternal }
        case .global: r = r.filter { $0.linkType == .global }
        case .all: break
        }
        if let pf = projectFilter { r = r.filter { $0.projectGroup == pf } }
        if updatesOnly { r = r.filter { app.effectiveStatus(for: $0) == .updateAvailable } }
        return r.sorted(using: sortOrder)
    }

    // MARK: Table

    private var table: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Skill", value: \.name) { s in
                HStack(spacing: 6) {
                    Image(systemName: s.linkType.symbol).font(.system(size: 10)).foregroundStyle(s.linkType.tint)
                    Text(s.name).fontWeight(.medium).lineLimit(1)
                }
                .help("\(s.name)\n\(s.path)")
            }.width(min: 150, ideal: 200)

            TableColumn("Link") { s in LinkBadge(type: s.linkType) }.width(92)

            TableColumn("Project") { s in projectCell(s) }.width(min: 120, ideal: 180)

            TableColumn("Scope", value: \.scope.rawValue) { s in
                Text(s.scope.label).foregroundStyle(.secondary)
            }.width(64)

            TableColumn("Source") { s in
                Text(s.source ?? "—")
                    .foregroundStyle(s.source == nil ? .tertiary : .secondary).lineLimit(1)
                    .help(s.source ?? "untracked")
            }.width(min: 120, ideal: 160)

            TableColumn("Version") { s in
                Text(s.shortVersion ?? "—").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }.width(66)

            TableColumn("Update") { s in updateCell(s) }.width(86)

            TableColumn("Agents") { s in
                Text(s.agents.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(s.agents.isEmpty ? "—" : s.agents.joined(separator: ", "))
            }.width(min: 90, ideal: 150)
        }
        .tableStyle(.inset)
    }

    @ViewBuilder private func projectCell(_ s: Skill) -> some View {
        if let label = s.projectLabel {
            HStack(spacing: 4) {
                if s.isWorktree {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Text(label).lineLimit(1)
            }
            .help(s.projectPath ?? label)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func updateCell(_ s: Skill) -> some View {
        let status = app.effectiveStatus(for: s)
        if app.updatingSkillIDs.contains(s.id) {
            ProgressView().controlSize(.small)
        } else if status == .updateAvailable {
            Button("Update") { Task { await app.updateSkill(s) } }
                .buttonStyle(.borderedProminent).tint(Theme.amber).controlSize(.small)
        } else {
            StatusBadge(status: status)
        }
    }
}

/// Pill showing a skill's link type (Local / Linked / Global / External) — symlinks use a link icon.
struct LinkBadge: View {
    let type: LinkType
    var body: some View {
        Label(type.label, systemImage: type.symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(type.tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(type.tint.opacity(0.14), in: Capsule())
            .help(type.help)
    }
}
