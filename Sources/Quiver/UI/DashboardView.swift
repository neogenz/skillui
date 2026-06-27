import SwiftUI
import AppKit

/// Full-window dashboard, Finder-style: a source-list sidebar carries navigation (scope,
/// per-project, the Updates smart group) so the content area stays one clean table. The
/// sidebar + window toolbar pick up Liquid Glass from the system on macOS 26 — nothing here
/// hand-rolls it. A project with several git worktrees expands to its worktrees in the sidebar;
/// selecting the whole project shows them all, tagged by worktree, while a single worktree drops
/// that column.
struct DashboardView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openSettings) private var openSettings

    @State private var nav: Nav? = .all
    @State private var search = ""
    @State private var selection = Set<Skill.ID>()
    @State private var sortOrder = [KeyPathComparator(\Skill.name)]

    /// Sidebar selection = the active filter. One control instead of three.
    enum Nav: Hashable {
        case all, updates
        case scope(Scope)
        case project(String)                          // a whole repo, every worktree
        case worktree(group: String, path: String)    // one worktree of that repo
    }

    private enum ProjectColumn { case hidden, project, worktree }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailPane
        }
        .frame(minWidth: 840, minHeight: 460)
        .task { if app.projectScanSkills.isEmpty { await app.scanProjects() } }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: Sidebar (source list)

    private var sidebar: some View {
        List(selection: $nav) {
            Section {
                Label("All Skills", systemImage: "square.grid.2x2")
                    .badge(app.dashboardSkills.count)
                    .tag(Nav.all)
                Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                    .badge(updatesCount)
                    .tag(Nav.updates)
            }
            Section("Library") {
                Label("Global", systemImage: "globe")
                    .badge(scopeCount(.global))
                    .tag(Nav.scope(.global))
                Label("Project", systemImage: "folder")
                    .badge(scopeCount(.project))
                    .tag(Nav.scope(.project))
            }
            if !projectGroups.isEmpty {
                Section("Projects") {
                    ForEach(projectGroups, id: \.self) { group in
                        projectRow(group)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 184, ideal: 208, max: 280)
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

    /// Offers to hydrate worktrees whose lockfile lists skills that never got installed.
    private var gapBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill").foregroundStyle(Theme.amber)
            // "worktree" isn't in the inflection dictionary, so pluralize by hand.
            Text("\(app.worktreeGaps.count) worktree\(app.worktreeGaps.count == 1 ? "" : "s") missing skills from their lockfile")
                .font(.system(size: 11))
            Spacer()
            Menu {
                if app.worktreeGaps.count > 1 {
                    Button("Install all (\(app.worktreeGaps.count))") {
                        Task { for gap in app.worktreeGaps { await app.installMissingSkills(at: gap.path) } }
                    }
                    Divider()
                }
                ForEach(app.worktreeGaps) { gap in
                    Button {
                        Task { await app.installMissingSkills(at: gap.path) }
                    } label: {
                        Text("\(gap.label) — ^[\(gap.missing.count) skill](inflect: true)")
                    }
                    .disabled(app.installingPaths.contains(gap.path))
                }
            } label: {
                if app.installingPaths.isEmpty {
                    Label("Install missing", systemImage: "arrow.down.circle")
                } else {
                    Label("Installing…", systemImage: "arrow.clockwise")
                }
            }
            .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.amber.opacity(0.1))
    }

    /// A project that spans several worktrees expands to them; a single-checkout project is a leaf.
    @ViewBuilder private func projectRow(_ group: String) -> some View {
        let trees = worktrees(in: group)
        if trees.count > 1 {
            DisclosureGroup {
                ForEach(trees) { tree in
                    Label(tree.name, systemImage: tree.isMain ? "shippingbox.fill" : "arrow.triangle.branch")
                        .badge(tree.count)
                        .tag(Nav.worktree(group: group, path: tree.path))
                        .help(tree.path)
                        .contextMenu { revealButton(tree.path) }
                }
            } label: {
                Label(group, systemImage: "shippingbox")
                    .badge(projectCount(group))
                    .tag(Nav.project(group))
                    .help("\(group) — \(trees.count) worktrees")
                    .contextMenu { revealButton(mainPath(trees)) }
            }
        } else {
            Label(group, systemImage: "shippingbox")
                .badge(projectCount(group))
                .tag(Nav.project(group))
                .help(group)
                .contextMenu { revealButton(trees.first?.path ?? "") }
        }
    }

    @ViewBuilder private func revealButton(_ path: String) -> some View {
        if !path.isEmpty {
            Button("Reveal in Finder", systemImage: "folder") { reveal([path]) }
        }
    }

    /// Folder to open for a whole project: its main checkout (falls back to any worktree).
    private func mainPath(_ trees: [WorktreeNode]) -> String {
        (trees.first { $0.isMain } ?? trees.first)?.path ?? ""
    }

    private func reveal(_ paths: [String]) {
        let urls = paths.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: Detail (toolbar + table)

    private var detailPane: some View {
        VStack(spacing: 0) {
            if !app.worktreeGaps.isEmpty { gapBanner }
            if app.isRateLimited && app.githubPAT.isEmpty { rateLimitBanner }
            table
        }
            .navigationTitle(navTitle)
            .navigationSubtitle("^[\(rows.count) skill](inflect: true)")
            .searchable(text: $search, placement: .toolbar, prompt: "Filter")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { Task { await app.rescanProjects() } } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(app.isScanningProjects)
                    .help("Rescan \(rootLabel)")
                }
                if app.isScanningProjects {
                    ToolbarItem(placement: .navigation) {
                        ProgressView().controlSize(.small)
                    }
                }
                if !updatableRows.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { Task { await app.updateMany(updatableRows) } } label: {
                            Label("Update all (\(updatableRows.count))", systemImage: "arrow.up.circle")
                        }
                        .prominentAction()
                        .help("Update the \(updatableRows.count) skills with updates in this view")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    rootMenu
                }
            }
    }

    private var rootMenu: some View {
        Menu {
            Section("Scan root") { Text(rootLabel) }
            Button("Change scan root…", systemImage: "folder") { chooseRoot() }
        } label: {
            Label(rootLabel, systemImage: "folder")
        }
        .help("Skills are discovered under this folder")
    }

    // MARK: Table

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Skill", value: \.name) { s in
                Text(s.name).fontWeight(.medium).lineLimit(1)
                    .help("\(s.name)\n\(s.path)")
            }.width(min: 160, ideal: 240)

            TableColumn("Link") { s in LinkBadge(type: s.linkType) }.width(92)

            if projectColumn != .hidden {
                TableColumn(projectColumn == .worktree ? "Worktree" : "Project") { s in
                    projectCell(s, mode: projectColumn)
                }.width(min: 120, ideal: 180)
            }

            TableColumn("Source") { s in
                Text(s.source ?? "—")
                    .foregroundStyle(s.source == nil ? .tertiary : .secondary).lineLimit(1)
                    .help(s.source ?? "untracked")
            }.width(min: 120, ideal: 160)

            TableColumn("Version") { s in
                Text(s.shortVersion ?? "—").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }.width(66)

            TableColumn("Update") { s in updateCell(s) }.width(84)

            TableColumn("Agents") { s in
                AgentChips(agents: s.agents, glass: false)
            }.width(min: 86, ideal: 130)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: Skill.ID.self) { ids in
            rowMenu(ids)
        } primaryAction: { ids in
            if ids.count == 1, let s = rows.first(where: { ids.contains($0.id) }) { open(s.skillsShURL) }
        }
        .overlay { emptyState }
    }

    @ViewBuilder private func rowMenu(_ ids: Set<Skill.ID>) -> some View {
        let picked = rows.filter { ids.contains($0.id) }
        if picked.count == 1, let s = picked.first {
            Button("Open on skills.sh", systemImage: "safari") { open(s.skillsShURL) }
            if s.githubURL != nil {
                Button("Open GitHub Repo", systemImage: "arrow.up.forward.app") { open(s.githubURL) }
            }
            Divider()
        }
        Button("Reveal in Finder", systemImage: "folder") { reveal(picked.map(\.path)) }
        let updatable = picked.filter { app.effectiveStatus(for: $0) == .updateAvailable }
        if !updatable.isEmpty {
            Divider()
            Button("Update \(updatable.count)", systemImage: "arrow.up.circle") {
                Task { await app.updateMany(updatable) }
            }
        }
    }

    private func open(_ url: URL?) { if let url { NSWorkspace.shared.open(url) } }

    @ViewBuilder private var emptyState: some View {
        if rows.isEmpty {
            if app.isScanningProjects {
                ContentUnavailableView { Label("Scanning projects…", systemImage: "magnifyingglass") }
            } else if app.dashboardSkills.isEmpty {
                ContentUnavailableView("No skills found", systemImage: "tray",
                    description: Text("Nothing under \(rootLabel). Change the scan root or add a skill with  npx skills add <owner/repo>."))
            } else {
                ContentUnavailableView {
                    Label("No matching skills", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Nothing here matches your filter.")
                } actions: {
                    Button("Reset") { resetFilters() }
                }
            }
        }
    }

    // MARK: Cells

    @ViewBuilder private func projectCell(_ s: Skill, mode: ProjectColumn) -> some View {
        if mode == .worktree {
            // The project is fixed by the sidebar selection, so each row just needs to say which
            // worktree it lives in — this is what tells the apparent "duplicates" apart.
            HStack(spacing: 4) {
                Image(systemName: s.isWorktree ? "arrow.triangle.branch" : "shippingbox.fill")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                Text(s.projectName ?? "—").lineLimit(1)
            }
            .help(s.projectPath ?? "")
        } else if let label = s.projectLabel {
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
                .prominentAction().controlSize(.small)
        } else {
            StatusBadge(status: status)
        }
    }

    // MARK: Derived state

    private var projectGroups: [String] {
        Array(Set(app.dashboardSkills.compactMap { $0.projectGroup }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var updatesCount: Int {
        app.dashboardSkills.reduce(into: 0) { n, s in if app.effectiveStatus(for: s) == .updateAvailable { n += 1 } }
    }
    /// Updatable skills within the current filtered view — drives the toolbar "Update all".
    private var updatableRows: [Skill] {
        rows.filter { app.effectiveStatus(for: $0) == .updateAvailable }
    }
    private func scopeCount(_ scope: Scope) -> Int { app.dashboardSkills.lazy.filter { $0.scope == scope }.count }
    private func projectCount(_ group: String) -> Int { app.dashboardSkills.lazy.filter { $0.projectGroup == group }.count }

    /// One node per distinct worktree (by its on-disk root) inside a repo group; main checkout first.
    private struct WorktreeNode: Identifiable, Hashable {
        let group: String, path: String, name: String, count: Int, isMain: Bool
        var id: String { path }
    }
    private func worktrees(in group: String) -> [WorktreeNode] {
        let byPath = Dictionary(grouping: app.dashboardSkills.filter { $0.projectGroup == group },
                                by: { $0.projectPath ?? "" })
        return byPath.map { path, skills in
            let s = skills[0]
            return WorktreeNode(group: group, path: path, name: s.projectName ?? group,
                                count: skills.count, isMain: !s.isWorktree)
        }
        .sorted { ($0.isMain ? 0 : 1, $0.name.lowercased()) < ($1.isMain ? 0 : 1, $1.name.lowercased()) }
    }

    /// Project column: a per-row repo when browsing across projects, a per-row worktree when one
    /// multi-worktree project is selected, hidden once the scope is a single worktree (pure repetition).
    private var projectColumn: ProjectColumn {
        switch nav {
        case .worktree: return .hidden
        case .project(let g): return worktrees(in: g).count > 1 ? .worktree : .hidden
        default: return .project
        }
    }

    private var navTitle: String {
        switch nav {
        case .updates: return "Updates"
        case .scope(let s): return s.label
        case .project(let p): return p
        case .worktree(_, let p): return (p as NSString).lastPathComponent
        case .all, .none: return "All Skills"
        }
    }

    private var rootLabel: String {
        app.scanRoot.isEmpty ? "Dev folders" : (app.scanRoot as NSString).abbreviatingWithTildeInPath
    }

    private var rows: [Skill] {
        var r = app.dashboardSkills
        switch nav {
        case .updates: r = r.filter { app.effectiveStatus(for: $0) == .updateAvailable }
        case .scope(let s): r = r.filter { $0.scope == s }
        case .project(let p): r = r.filter { $0.projectGroup == p }
        case .worktree(let g, let p): r = r.filter { $0.projectGroup == g && ($0.projectPath ?? "") == p }
        case .all, .none: break
        }
        if !search.isEmpty {
            r = r.filter {
                $0.name.localizedCaseInsensitiveContains(search)
                    || ($0.source?.localizedCaseInsensitiveContains(search) ?? false)
                    || ($0.projectLabel?.localizedCaseInsensitiveContains(search) ?? false)
            }
        }
        return r.sorted(using: sortOrder)
    }

    // MARK: Actions

    private func resetFilters() { nav = .all; search = "" }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Scan here"
        if panel.runModal() == .OK, let url = panel.url {
            app.scanRoot = url.path
            Task { await app.rescanProjects() }
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
