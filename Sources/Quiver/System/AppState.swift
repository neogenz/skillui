import SwiftUI
import Observation

/// Central app coordinator. Holds the in-memory skill list + update statuses, drives
/// scans and update checks. Nothing is persisted except the update cache (Group C) and
/// user settings (UserDefaults). The skill list is re-derived on every scan.
@MainActor
@Observable
final class AppState {
    var skills: [Skill] = []
    var statuses: [String: UpdateStatus] = [:]   // skill.id → status
    var isScanning = false
    var isCheckingUpdates = false
    var hasScannedOnce = false
    var lastError: String?
    var cliMissing = false
    var updatingSkillIDs: Set<String> = []
    var lastCheckedAt: Date?
    /// Set by the rate-limit banner so Settings focuses the PAT field on open.
    var requestPATFocus = false

    // Recursive multi-project scan (Dashboard)
    var projectScanSkills: [Skill] = []
    var discoveredProjects: [String] = []
    var isScanningProjects = false
    var lastProjectScanAt: Date?

    // MARK: Settings (persisted to UserDefaults)

    var cliPathOverride: String {
        didSet { defaults.set(cliPathOverride, forKey: K.cliPath); cachedInvocation = nil }
    }
    var projectRoots: [String] {
        didSet {
            // Normalize + de-dup so the same folder can't yield duplicate skill rows.
            let norm = Set(projectRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }).sorted()
            if norm != projectRoots { projectRoots = norm; return }
            defaults.set(projectRoots, forKey: K.projectRoots)
        }
    }
    var refreshIntervalHours: Double {
        didSet { defaults.set(refreshIntervalHours, forKey: K.refreshHours); startBackgroundRefresh() }
    }
    var hiddenAgents: Set<String> {
        didSet { defaults.set(Array(hiddenAgents), forKey: K.hiddenAgents) }
    }
    /// Root scanned recursively for projects (default: home).
    var scanRoot: String {
        didSet { defaults.set(scanRoot, forKey: K.scanRoot) }
    }
    /// Reference global-skills root for link classification (default: ~/.agents/skills).
    var globalSkillsRootOverride: String {
        didSet { defaults.set(globalSkillsRootOverride, forKey: K.globalRoot) }
    }
    /// Scan projects automatically on launch + each refresh.
    var autoScanProjects: Bool {
        didSet { defaults.set(autoScanProjects, forKey: K.autoScan) }
    }
    /// GitHub PAT — stored in the Keychain, never UserDefaults.
    var githubPAT: String {
        didSet { Keychain.setToken(githubPAT.isEmpty ? nil : githubPAT) }
    }
    /// Launch-at-login, reflected straight from SMAppService.
    var launchAtLogin: Bool {
        get { LoginItem.isEnabled }
        set { try? LoginItem.setEnabled(newValue) }
    }

    private let defaults = UserDefaults.standard
    private enum K {
        static let cliPath = "cliPathOverride"
        static let projectRoots = "projectRoots"
        static let refreshHours = "refreshIntervalHours"
        static let hiddenAgents = "hiddenAgents"
        static let scanRoot = "scanRoot"
        static let globalRoot = "globalSkillsRootOverride"
        static let autoScan = "autoScanProjects"
    }
    private var cachedInvocation: [String]?
    private let cacheStore = UpdateCacheStore()
    private var refreshTask: Task<Void, Never>?
    /// Serial chain: refresh / updateSkill / updateAll run one at a time (never interleave
    /// at await points), so spinners, statuses and the rate limit stay consistent.
    private var tail: Task<Void, Never> = Task {}

    private func serialize(_ op: @escaping @MainActor () async -> Void) async {
        let prev = tail
        let t = Task { @MainActor in await prev.value; await op() }
        tail = t
        await t.value
    }

    /// All agent display names across discovered skills (for the Settings filter list).
    var allAgents: [String] { Array(Set(skills.flatMap(\.agents))).sorted() }

    /// Skills after per-agent visibility (hide skills whose agents are ALL hidden).
    var visibleSkills: [Skill] {
        guard !hiddenAgents.isEmpty else { return skills }
        return skills.filter { !$0.agents.allSatisfy(hiddenAgents.contains) }
    }

    private func githubToken() -> String? { Keychain.token() }

    /// Periodic unattended refresh. Restarted when the interval changes.
    func startBackgroundRefresh() {
        refreshTask?.cancel()
        let hours = refreshIntervalHours
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(0.25, hours) * 3600))
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    init() {
        cliPathOverride = defaults.string(forKey: K.cliPath) ?? ""
        projectRoots = defaults.stringArray(forKey: K.projectRoots) ?? []
        refreshIntervalHours = defaults.object(forKey: K.refreshHours) as? Double ?? 6
        hiddenAgents = Set(defaults.stringArray(forKey: K.hiddenAgents) ?? [])
        scanRoot = defaults.string(forKey: K.scanRoot) ?? ""
        globalSkillsRootOverride = defaults.string(forKey: K.globalRoot) ?? ""
        autoScanProjects = defaults.object(forKey: K.autoScan) as? Bool ?? true
        githubPAT = Keychain.token() ?? ""
        // Don't auto-refresh in the headless dev hooks (they drive their own scan + exit).
        let headless = CommandLine.arguments.contains { a in
            a.hasPrefix("--render") || a.hasPrefix("--scan") || a.hasPrefix("--login")
        }
        if !headless { startBackgroundRefresh() }
    }

    var updateCount: Int {
        skills.reduce(into: 0) { acc, s in if statuses[s.id] == .updateAvailable { acc += 1 } }
    }

    // MARK: Discovery

    private func resolveCLI() async -> [String]? {
        if let cachedInvocation { return cachedInvocation }
        let inv = await ShellEnvironment.resolveSkillsInvocation(
            override: cliPathOverride.isEmpty ? nil : cliPathOverride)
        cachedInvocation = inv
        return inv
    }

    func scan() async {
        isScanning = true
        defer { isScanning = false }

        guard let invocation = await resolveCLI() else {
            cliMissing = true
            lastError = "Couldn't find `skills` or `npx`. Set a path in Settings."
            skills = []
            return
        }
        cliMissing = false

        let globalRoots = LinkClassifier.defaultGlobalRoots(
            customGlobalRoot: globalSkillsRootOverride.isEmpty ? nil : globalSkillsRootOverride)
        let scanner = SkillScanner(cli: SkillsCLI(invocation: invocation),
                                   projectRoots: projectRoots, globalRoots: globalRoots)
        let outcome = await scanner.scan()
        skills = outcome.skills.sorted(by: Self.order)
        lastError = outcome.error

        // Prune statuses for skills that disappeared.
        let liveIDs = Set(skills.map(\.id))
        statuses = statuses.filter { liveIDs.contains($0.key) }
        hasScannedOnce = true
    }

    /// Full refresh: rescan + recheck updates (cache-guarded unless forced). Serialized.
    func refresh(force: Bool = false) async {
        await serialize {
            await self.scan()
            await self.checkUpdates(force: force)
            self.lastCheckedAt = Date()
        }
        // Project scan is NOT in the serial block: it touches disjoint state, so globals
        // appear immediately while the (slower) recursive walk runs in the background.
        if autoScanProjects { await scanProjects() }
    }

    // MARK: Multi-project scan (Dashboard)

    /// Rescan now, ignoring freshness (Rescan button).
    func rescanProjects() async { await scanProjects(force: true) }

    /// Recursively scan projects under the configured root. Single-flight + TTL-guarded so
    /// repeated panel opens don't re-walk the whole home.
    func scanProjects(force: Bool = false) async {
        if isScanningProjects { return }
        if !force, let last = lastProjectScanAt,
           Date().timeIntervalSince(last) < max(0.25, refreshIntervalHours) * 3600 { return }
        isScanningProjects = true
        defer { isScanningProjects = false }
        // Default to known dev-project roots (never the whole home — that would touch
        // ~/Documents, ~/Music, ~/Pictures, … and trigger macOS privacy prompts).
        let roots: [String] = scanRoot.isEmpty
            ? Self.defaultDevRoots()
            : [(scanRoot as NSString).expandingTildeInPath]
        let globalRoots = LinkClassifier.defaultGlobalRoots(
            customGlobalRoot: globalSkillsRootOverride.isEmpty ? nil : globalSkillsRootOverride)
        let scanner = FilesystemScanner(globalRoots: globalRoots)
        // FS walk + enumeration are synchronous — run off the main actor.
        let projects = await Task.detached(priority: .utility) {
            roots.flatMap { ProjectFinder(root: $0).find() }
        }.value
        let found = await Task.detached(priority: .utility) { scanner.scan(projectRoots: projects) }.value
        discoveredProjects = projects
        projectScanSkills = found.sorted(by: Self.order)
        lastProjectScanAt = Date()

        // Evaluate update status for comparable project skills (project-local via local git
        // tree SHA, grouped per repo). Linked-global skills are mapped via effectiveStatus.
        let checker = UpdateChecker(token: githubToken(), cache: cacheStore)
        let comparable = projectScanSkills.filter { $0.canCheckUpdate }
        if !comparable.isEmpty {
            for s in comparable where statuses[s.id] != .updateAvailable { statuses[s.id] = .checking }
            let results = await checker.evaluate(comparable)
            for (id, st) in results { statuses[id] = st }
        }
    }

    /// True when any update check failed due to GitHub rate limiting — surfaced as a banner
    /// suggesting a personal access token.
    var isRateLimited: Bool {
        statuses.values.contains {
            if case .failed(let m) = $0 { return m.localizedCaseInsensitiveContains("rate limit") }
            return false
        }
    }

    /// Common dev-project roots under home, scanned by default. Avoids the whole home (and its
    /// macOS-protected ~/Documents, ~/Music, ~/Pictures, …). Set a custom root in Settings to override.
    static func defaultDevRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let names = ["workspace", "Developer", "dev", "Projects", "projects",
                     "code", "Code", "src", "git", "repos", "work", "Sites"]
        return names.map { "\(home)/\($0)" }.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// All skills for the dashboard: global (CLI-accurate) + recursively-scanned project skills.
    var dashboardSkills: [Skill] {
        skills.filter { $0.scope == .global } + projectScanSkills
    }

    /// Update status, mapping a project's linked-global skill to its global counterpart.
    func effectiveStatus(for s: Skill) -> UpdateStatus {
        if let st = statuses[s.id] { return st }
        if s.linkType == .linkedGlobal,
           let g = skills.first(where: { $0.scope == .global && $0.name == s.name }) {
            return statuses[g.id] ?? .unsupported
        }
        return .unsupported
    }

    // MARK: Actions (mutating — user-initiated only)

    /// `skills update <name>` for one skill, then rescan + recheck so the badge clears.
    /// Marks the row "updating" immediately (before the serial queue) so a click during an
    /// in-flight update gives instant feedback instead of appearing to do nothing.
    func updateSkill(_ skill: Skill) async {
        // Flip the row to its spinner the instant the user clicks — and dedupe: ignore repeat
        // taps while this skill is already queued or running. Marking here (not inside the
        // serialized op) means queued skills show feedback immediately instead of only when
        // their turn comes, which is what made extra clicks feel like "nothing happens".
        guard !updatingSkillIDs.contains(skill.id) else { return }
        updatingSkillIDs.insert(skill.id)
        await serialize {
            defer { self.updatingSkillIDs.remove(skill.id) }
            guard let invocation = await self.resolveCLI() else { return }
            do {
                try await SkillsCLI(invocation: invocation)
                    .update(name: skill.name, scope: skill.scope, cwd: skill.projectPath)
                await self.scan()
                await self.checkUpdates(force: true)
                await self.reevaluateProjectStatuses([skill])
            } catch {
                self.lastError = "Update failed for \(skill.name): \(error.localizedDescription)"
            }
        }
    }

    /// Re-evaluate update status for specific project-scope skills directly from their (now
    /// changed) on-disk folder. Used after an update instead of a full recursive project
    /// re-walk: the walk is slow — pinning the row spinner for its whole duration — and its
    /// `isScanningProjects` single-flight guard can silently drop a forced run while a
    /// background refresh / Rescan is mid-walk, leaving the just-updated badge stale.
    private func reevaluateProjectStatuses(_ candidates: [Skill]) async {
        let checkable = candidates.filter { $0.scope == .project && $0.canCheckUpdate }
        guard !checkable.isEmpty else { return }
        let checker = UpdateChecker(token: githubToken(), cache: cacheStore)
        let results = await checker.evaluate(checkable, force: true)
        for (id, st) in results { statuses[id] = st }
    }

    /// Update every skill the panel currently flags `updateAvailable` (global + configured roots).
    func updateAll() async {
        await updateMany(skills.filter { statuses[$0.id] == .updateAvailable })
    }

    /// Update a specific set of skills — e.g. the dashboard's current filtered view, which is
    /// drawn from the recursive project scan rather than `skills`. Serialized like the rest.
    func updateMany(_ targets: [Skill]) async {
        guard !targets.isEmpty else { return }
        // Light every target row's spinner at once so the whole batch reads as "in progress".
        let ids = Set(targets.map(\.id))
        for id in ids { updatingSkillIDs.insert(id) }
        // One `skills update` per distinct on-disk skill: the recursive scan can list the same
        // folder several times (shared agent dirs, worktrees), and a single update covers them all.
        var seen = Set<String>()
        let distinct = targets.filter {
            seen.insert("\($0.scope.rawValue)|\($0.projectPath ?? "")|\($0.name)").inserted
        }
        await serialize {
            defer { self.updatingSkillIDs.subtract(ids) }
            guard let invocation = await self.resolveCLI() else { return }
            let cli = SkillsCLI(invocation: invocation)
            // Gate on the live status: a per-row updateSkill that landed first may have already
            // cleared one of these, so re-running `skills update` on it would be redundant.
            for t in distinct where self.effectiveStatus(for: t) == .updateAvailable {
                do { try await cli.update(name: t.name, scope: t.scope, cwd: t.projectPath) }
                catch { self.lastError = "Update failed for \(t.name): \(error.localizedDescription)" }
            }
            await self.scan()
            await self.checkUpdates(force: true)
            await self.reevaluateProjectStatuses(targets)
        }
    }

    /// Recheck update status for all skills. Grouped per repo inside `UpdateChecker.evaluate`,
    /// so the verdict is decided per skill against a single tree fetch per (repo, ref).
    func checkUpdates(force: Bool = false) async {
        guard !skills.isEmpty else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }

        for s in skills where !s.canCheckUpdate { statuses[s.id] = .unsupported }
        let checkable = skills.filter { $0.canCheckUpdate }
        for s in checkable where statuses[s.id] != .updateAvailable { statuses[s.id] = .checking }

        let checker = UpdateChecker(token: githubToken(), cache: cacheStore)
        let results = await checker.evaluate(checkable, force: force)
        for (id, status) in results { statuses[id] = status }
    }

    private static func order(_ a: Skill, _ b: Skill) -> Bool {
        if a.scope != b.scope { return a.scope == .global }   // global section first
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
