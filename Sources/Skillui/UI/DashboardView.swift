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
    @State private var expandedGroups: [String: Bool] = [:]

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
        .onAppear { app.enterRegularActivation() }
        .onDisappear { app.leaveRegularActivation() }
    }

    // MARK: Sidebar (source list)

    private var sidebar: some View {
        // Snapshot + group the dashboard skills ONCE per sidebar build. `app.dashboardSkills` is a
        // computed property that allocates a fresh array on each access, and the old code re-filtered
        // it per project group (O(P·N) plus P fresh allocations) — the cost grew exactly with the
        // dashboard's headline job of scanning many projects. Derive the per-group slices up front.
        let dashboardSkills = app.dashboardSkills
        let byGroup = Dictionary(grouping: dashboardSkills, by: { $0.projectGroup })
        let scopeCounts = Dictionary(grouping: dashboardSkills, by: { $0.scope }).mapValues(\.count)
        let groups = projectGroups(dashboardSkills)
        return List(selection: $nav) {
            Section {
                Label("All Skills", systemImage: "square.grid.2x2")
                    .badge(dashboardSkills.count)
                    .tag(Nav.all)
                Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                    .badge(updatesCount)
                    .tag(Nav.updates)
            }
            Section("Library") {
                Label("Global", systemImage: "globe")
                    .badge(scopeCounts[.global] ?? 0)
                    .tag(Nav.scope(.global))
                Label("Project", systemImage: "folder")
                    .badge(scopeCounts[.project] ?? 0)
                    .tag(Nav.scope(.project))
            }
            if !groups.isEmpty {
                Section("Projects") {
                    ForEach(groups, id: \.self) { group in
                        projectRow(group, skills: byGroup[group] ?? [])
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

    private var keychainBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill").foregroundStyle(Theme.statusWarn)
            Text("GitHub token is protected by Keychain. Authorize the existing token or replace it in Settings.")
                .font(.system(size: 11))
            Spacer()
            Button("Open Settings") { app.requestPATFocus = true; openSettings() }.controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.statusWarn.opacity(0.12))
    }

    /// Offers to hydrate worktrees whose lockfile lists skills that never got installed. Counts and
    /// installs only what's cloneable; worktrees whose only gap is a non-git source are flagged but
    /// never offered an install (the action would be a no-op).
    private var gapBanner: some View {
        let gaps = app.worktreeGaps
        let actionable = gaps.filter { !$0.installable.isEmpty }
        let blockedSkills = gaps.reduce(0) { $0 + $1.blocked.count }
        let tint = actionable.isEmpty ? Color.secondary : Theme.amber
        return HStack(spacing: 8) {
            Image(systemName: actionable.isEmpty ? "exclamationmark.triangle" : "shippingbox.fill")
                .foregroundStyle(tint)
            Text(gapBannerHeadline(actionableWorktrees: actionable.count, blockedSkills: blockedSkills, totalWorktrees: gaps.count))
                .font(.system(size: 11))
            Spacer()
            if !actionable.isEmpty {
                Menu {
                    if actionable.count > 1 {
                        Button("Install all (\(actionable.count))") {
                            Task { await app.installMissingSkills(at: actionable.map(\.path)) }
                        }
                        Divider()
                    }
                    ForEach(actionable) { gap in
                        Button {
                            Task { await app.installMissingSkills(at: gap.path) }
                        } label: {
                            Text("\(gap.label) — ^[\(gap.installable.count) skill](inflect: true)")
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
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(tint.opacity(0.1))
    }

    /// Never claims "0 missing" when blocked skills are in fact missing — an all-blocked banner says
    /// so plainly instead of offering a phantom install.
    private func gapBannerHeadline(actionableWorktrees: Int, blockedSkills: Int, totalWorktrees: Int) -> String {
        if actionableWorktrees == 0 {
            return "\(totalWorktrees) worktree\(totalWorktrees == 1 ? "" : "s") with skills that can't be auto-installed (non-git source)"
        }
        var s = "\(actionableWorktrees) worktree\(actionableWorktrees == 1 ? "" : "s") missing skills from their lockfile"
        if blockedSkills > 0 { s += " · \(blockedSkills) skill\(blockedSkills == 1 ? "" : "s") blocked (non-git source)" }
        return s
    }

    /// `gapBanner` scoped to the project/worktree in focus, so the action reads as "install *these*
    /// skills, here" instead of a global catch-all. Shown only when something is already installed
    /// (otherwise the empty-state CTA carries it).
    private var contextualGapBanner: some View {
        let gaps = focusedGaps
        let installable = gaps.reduce(0) { $0 + $1.installable.count }
        let blocked = gaps.reduce(0) { $0 + $1.blocked.count }
        let installing = gaps.allSatisfy { app.installingPaths.contains($0.path) }
        let scope = gaps.count == 1 ? gaps[0].label : navTitle
        let tint = installable > 0 ? Theme.amber : Color.secondary
        return HStack(spacing: 8) {
            Image(systemName: installable > 0 ? "shippingbox.fill" : "exclamationmark.triangle")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                if installable > 0 {
                    Text("\(scope) — ^[\(installable) skill](inflect: true) declared but not installed")
                        .font(.system(size: 11))
                    if blocked > 0 {
                        Text("^[\(blocked) skill](inflect: true) can't be auto-installed (non-git source)")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(scope) — ^[\(blocked) skill](inflect: true) can't be auto-installed (non-git source)")
                        .font(.system(size: 11))
                }
            }
            Spacer()
            if installable > 0 {
                Button {
                    Task { await app.installMissingSkills(at: gaps.filter { !$0.installable.isEmpty }.map(\.path)) }
                } label: {
                    if installing {
                        Label("Installing…", systemImage: "arrow.clockwise")
                    } else {
                        Label("Install \(installable) skill\(installable == 1 ? "" : "s")", systemImage: "arrow.down.circle")
                    }
                }
                .controlSize(.small)
                .disabled(installing)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(tint.opacity(0.1))
    }

    /// A project that spans several worktrees expands to them; a single-checkout project is a leaf.
    @ViewBuilder private func projectRow(_ group: String, skills groupSkills: [Skill]) -> some View {
        let trees = worktrees(in: group, skills: groupSkills)
        if trees.count > 1 {
            DisclosureGroup(isExpanded: expansion(for: group, trees: trees)) {
                ForEach(trees) { tree in
                    worktreeLabel(tree, group: group)
                }
            } label: {
                Label(group, systemImage: "shippingbox")
                    .badge(groupSkills.count)
                    .tag(Nav.project(group))
                    .help("\(group) — \(trees.count) worktrees")
                    .contextMenu {
                        revealButton(mainPath(trees))
                        copyPathButton(mainPath(trees))
                    }
            }
        } else if let only = trees.first {
            worktreeLabel(only, group: group, leaf: true)
        } else {
            Label(group, systemImage: "shippingbox").badge(groupSkills.count).tag(Nav.project(group))
        }
    }

    /// Projects with an incomplete worktree start expanded so it's seen, not buried; the user's
    /// own collapse/expand wins after that.
    private func expansion(for group: String, trees: [WorktreeNode]) -> Binding<Bool> {
        Binding(
            get: { expandedGroups[group] ?? trees.contains { $0.missing > 0 } },
            set: { expandedGroups[group] = $0 }
        )
    }

    /// One worktree row — a filled warning when it has installable gaps, a hollow one when its only
    /// gap is a non-git source (nothing to click), the normal box otherwise.
    @ViewBuilder private func worktreeLabel(_ tree: WorktreeNode, group: String, leaf: Bool = false) -> some View {
        let icon = tree.installable > 0 ? "exclamationmark.triangle.fill"
            : tree.blocked > 0 ? "exclamationmark.triangle"
            : leaf ? "shippingbox" : (tree.isMain ? "shippingbox.fill" : "arrow.triangle.branch")
        Label(tree.name, systemImage: icon)
            .badge(tree.count)
            .tag(leaf ? Nav.project(group) : Nav.worktree(group: group, path: tree.path))
            .help(worktreeHelp(tree))
            .contextMenu {
                revealButton(tree.path)
                copyPathButton(tree.path)
                if tree.installable > 0 {
                    Button("Install \(tree.installable) missing skill\(tree.installable == 1 ? "" : "s")", systemImage: "arrow.down.circle") {
                        Task { await app.installMissingSkills(at: tree.path) }
                    }
                    .disabled(app.installingPaths.contains(tree.path))
                }
                if tree.blocked > 0 {
                    Text("\(tree.blocked) skill\(tree.blocked == 1 ? "" : "s") can't be installed (non-git source)")
                }
            }
    }

    private func worktreeHelp(_ tree: WorktreeNode) -> String {
        var parts = [tree.path]
        if tree.installable > 0 { parts.append("\(tree.installable) declared but not installed") }
        if tree.blocked > 0 { parts.append("\(tree.blocked) blocked (non-git source)") }
        return parts.joined(separator: "\n")
    }

    @ViewBuilder private func revealButton(_ path: String) -> some View {
        if !path.isEmpty {
            Button("Reveal in Finder", systemImage: "folder") { reveal([path]) }
        }
    }

    @ViewBuilder private func copyPathButton(_ path: String) -> some View {
        if !path.isEmpty {
            Button("Copy path", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
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
        // Derive the filtered+sorted rows ONCE per body. `rows` runs a filter + full sort, and was
        // read ~4-6× per pass (subtitle count, the toolbar's "Update all", the table, the empty-state
        // overlay), re-running on every search keystroke and status change. `updatableRows` folded in.
        let rows = self.rows
        let updatable = rows.filter { app.effectiveStatus(for: $0) == .updateAvailable }
        return VStack(spacing: 0) {
            // Focused on a project/worktree with a gap → scope the install affordance to it. With
            // something installed it's a slim banner above the table; with nothing installed the CTA
            // lives in the empty state instead (see `emptyState`) so we never stack two install buttons.
            // Any other view keeps the global "all worktrees" banner.
            if !focusedGaps.isEmpty {
                if !rows.isEmpty { contextualGapBanner }
            } else if !app.worktreeGaps.isEmpty {
                gapBanner
            }
            if app.githubCredentialNeedsAttention { keychainBanner }
            if app.isRateLimited && !app.hasConfiguredGitHubCredential { rateLimitBanner }
            table(rows)
        }
            .navigationTitle(navTitle)
            .navigationSubtitle("^[\(rows.count) skill](inflect: true)")
            .searchable(text: $search, placement: .toolbar, prompt: "Filter")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    // One control that shows its own progress — a bare ProgressView as a second
                    // toolbar item gets its own awkwardly-padded glass capsule on macOS 26.
                    Button { Task { await app.refresh(force: true) } } label: {
                        if app.isScanning || app.isScanningProjects {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Rescan", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(app.isScanning || app.isScanningProjects)
                    .help("Refresh global skills + rescan \(rootLabel)")
                }
                if app.updateActivity != nil {
                    ToolbarItem(placement: .navigation) {
                        Button { app.presentUpdateActivityWindow() } label: {
                            Label("Activity", systemImage: "doc.text")
                        }
                        .help("Open the latest update activity log")
                    }
                }
                if !updatable.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { Task { await app.updateMany(updatable) } } label: {
                            Label("Update all (\(updatable.count))", systemImage: "arrow.up.circle")
                        }
                        .prominentAction()
                        .help("Update the \(updatable.count) skills with updates in this view")
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

    private func table(_ rows: [Skill]) -> some View {
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
            rowMenu(ids, in: rows)
        } primaryAction: { ids in
            if ids.count == 1, let s = rows.first(where: { ids.contains($0.id) }) { open(s.skillsShURL) }
        }
        .overlay { emptyState(rows) }
    }

    @ViewBuilder private func rowMenu(_ ids: Set<Skill.ID>, in rows: [Skill]) -> some View {
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

    @ViewBuilder private func emptyState(_ rows: [Skill]) -> some View {
        if rows.isEmpty {
            if app.isScanningProjects {
                ContentUnavailableView { Label("Scanning projects…", systemImage: "magnifyingglass") }
            } else if !focusedGaps.isEmpty && search.isEmpty {
                // Focused on a project whose lockfile skills aren't on disk yet: the "empty list"
                // becomes a scoped install CTA. Must precede the generic branches below — gaps are
                // lockfile-derived and can coexist with an otherwise-empty dashboard on a fresh machine.
                let installable = focusedGaps.reduce(0) { $0 + $1.installable.count }
                let blocked = focusedGaps.reduce(0) { $0 + $1.blocked.count }
                let installing = focusedGaps.allSatisfy { app.installingPaths.contains($0.path) }
                let scope = focusedGaps.count == 1 ? focusedGaps[0].label : navTitle
                if installable > 0 {
                    ContentUnavailableView {
                        Label("Skills not installed yet", systemImage: "shippingbox")
                    } description: {
                        if blocked > 0 {
                            Text("\(scope) declares ^[\(installable) skill](inflect: true) to install. ^[\(blocked) other skill](inflect: true) can't be auto-installed (non-git source).")
                        } else {
                            Text("\(scope) declares ^[\(installable) skill](inflect: true) in its lockfile that aren't installed in this folder.")
                        }
                    } actions: {
                        Button {
                            Task { await app.installMissingSkills(at: focusedGaps.filter { !$0.installable.isEmpty }.map(\.path)) }
                        } label: {
                            Label(installing ? "Installing…" : "Install \(installable) skill\(installable == 1 ? "" : "s")",
                                  systemImage: installing ? "arrow.clockwise" : "arrow.down.circle")
                        }
                        .prominentAction()
                        .disabled(installing)
                    }
                } else {
                    // Every remaining gap is a non-git source — no install button, an honest title.
                    let sources = Set(focusedGaps.flatMap { $0.blocked.compactMap(\.package) }).sorted()
                    ContentUnavailableView {
                        Label("These skills can't be installed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("\(scope) declares ^[\(blocked) skill](inflect: true) whose source isn't a git repository\(sources.isEmpty ? "" : " (\(sources.joined(separator: ", ")))"), so it can't be auto-installed.")
                    }
                }
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

    private func projectGroups(_ dashboardSkills: [Skill]) -> [String] {
        // Include groups that only show up via gaps (a worktree with a lockfile but no installed
        // skills) so the tree lists it even before anything is hydrated.
        let fromSkills = dashboardSkills.compactMap { $0.projectGroup }
        let fromGaps = app.worktreeGaps.map(\.group)
        return Array(Set(fromSkills + fromGaps))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var updatesCount: Int {
        app.dashboardSkills.reduce(into: 0) { n, s in if app.effectiveStatus(for: s) == .updateAvailable { n += 1 } }
    }

    /// One node per distinct worktree (by its on-disk root) inside a repo group; main checkout first.
    private struct WorktreeNode: Identifiable, Hashable {
        let group: String, path: String, name: String, count: Int, isMain: Bool
        let missing: Int       // total gap (installable + blocked) — drives auto-expand
        let installable: Int   // cloneable, what the install action acts on
        let blocked: Int       // non-git source, surfaced but not installable
        var id: String { path }
    }
    /// Single-group convenience (used by `projectColumn`); the sidebar passes its precomputed slice.
    private func worktrees(in group: String) -> [WorktreeNode] {
        worktrees(in: group, skills: app.dashboardSkills.filter { $0.projectGroup == group })
    }
    private func worktrees(in group: String, skills groupSkills: [Skill]) -> [WorktreeNode] {
        let byPath = Dictionary(grouping: groupSkills, by: { $0.projectPath ?? "" })
        // Worktrees that have a lockfile but nothing (or little) installed only show up as gaps —
        // union them in so the tree lists them, flagged, instead of hiding them until hydrated.
        let gaps = Dictionary(app.worktreeGaps.filter { $0.group == group }.map { ($0.path, $0) },
                              uniquingKeysWith: { a, _ in a })
        let paths = Set(byPath.keys).union(gaps.keys)
        return paths.map { path -> WorktreeNode in
            let skills = byPath[path] ?? []
            let gap = gaps[path]
            let name = skills.first?.projectName ?? gap?.name ?? (path as NSString).lastPathComponent
            let isMain = skills.first.map { !$0.isWorktree } ?? !(gap?.isWorktree ?? false)
            return WorktreeNode(group: group, path: path, name: name,
                                count: skills.count, isMain: isMain,
                                missing: gap?.missing.count ?? 0,
                                installable: gap?.installable.count ?? 0,
                                blocked: gap?.blocked.count ?? 0)
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

    /// Gaps belonging to the project/worktree currently in focus. A single-checkout repo row is
    /// tagged `.project` (not `.worktree`), so the common case lands in the `.project` branch.
    private var focusedGaps: [WorktreeGap] {
        switch nav {
        case .worktree(_, let p): return app.worktreeGaps.filter { $0.path == p }
        case .project(let g): return app.worktreeGaps.filter { $0.group == g }
        default: return []
        }
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
