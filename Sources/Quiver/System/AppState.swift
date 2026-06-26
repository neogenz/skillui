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

    // MARK: Settings (persisted to UserDefaults)

    var cliPathOverride: String {
        didSet { defaults.set(cliPathOverride, forKey: K.cliPath); cachedInvocation = nil }
    }
    var projectRoots: [String] {
        didSet { defaults.set(projectRoots, forKey: K.projectRoots) }
    }
    var refreshIntervalHours: Double {
        didSet { defaults.set(refreshIntervalHours, forKey: K.refreshHours); startBackgroundRefresh() }
    }
    var hiddenAgents: Set<String> {
        didSet { defaults.set(Array(hiddenAgents), forKey: K.hiddenAgents) }
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
    }
    private var cachedInvocation: [String]?
    private let cacheStore = UpdateCacheStore()
    private var refreshTask: Task<Void, Never>?

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
        githubPAT = Keychain.token() ?? ""
        // Don't auto-refresh in the headless dev hooks (they drive their own scan + exit).
        let headless = CommandLine.arguments.contains("--scan-dump")
            || CommandLine.arguments.contains("--render-png")
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

        let scanner = SkillScanner(cli: SkillsCLI(invocation: invocation), projectRoots: projectRoots)
        let outcome = await scanner.scan()
        skills = outcome.skills.sorted(by: Self.order)
        lastError = outcome.error

        // Prune statuses for skills that disappeared.
        let liveIDs = Set(skills.map(\.id))
        statuses = statuses.filter { liveIDs.contains($0.key) }
        hasScannedOnce = true
    }

    /// Full refresh: rescan + recheck updates (cache-guarded unless forced).
    func refresh(force: Bool = false) async {
        await scan()
        await checkUpdates(force: force)
        lastCheckedAt = Date()
    }

    // MARK: Actions (mutating — user-initiated only)

    /// `skills update <name>` for one skill, then rescan + recheck so the badge clears.
    func updateSkill(_ skill: Skill) async {
        guard let invocation = await resolveCLI() else { return }
        updatingSkillIDs.insert(skill.id)
        defer { updatingSkillIDs.remove(skill.id) }
        do {
            try await SkillsCLI(invocation: invocation)
                .update(name: skill.name, scope: skill.scope, cwd: skill.projectPath)
            await scan()
            await checkUpdates(force: true)
        } catch {
            lastError = "Update failed for \(skill.name): \(error.localizedDescription)"
        }
    }

    /// Update every skill currently flagged `updateAvailable`, then a single rescan/recheck.
    func updateAll() async {
        guard let invocation = await resolveCLI() else { return }
        let cli = SkillsCLI(invocation: invocation)
        let targets = skills.filter { statuses[$0.id] == .updateAvailable }
        guard !targets.isEmpty else { return }
        for t in targets {
            updatingSkillIDs.insert(t.id)
            do { try await cli.update(name: t.name, scope: t.scope, cwd: t.projectPath) }
            catch { lastError = "Update failed for \(t.name): \(error.localizedDescription)" }
            updatingSkillIDs.remove(t.id)
        }
        await scan()
        await checkUpdates(force: true)
    }

    func checkUpdates(force: Bool = false) async {
        guard !skills.isEmpty else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }

        let checker = UpdateChecker(token: githubToken(), cache: cacheStore)

        // Untracked / computedHash-only skills can't be tree-SHA checked.
        for s in skills where !s.canCheckUpdate { statuses[s.id] = .unsupported }

        // Dedup by updateKey: many skills can share one (source, ref, folder).
        let checkable = skills.filter { $0.canCheckUpdate }
        for s in checkable where statuses[s.id] != .updateAvailable { statuses[s.id] = .checking }

        var byKey: [String: [Skill]] = [:]
        for s in checkable { if let k = s.updateKey { byKey[k, default: []].append(s) } }

        let keys = Array(byKey.keys)
        let maxConcurrent = 5
        var next = 0

        await withTaskGroup(of: (String, UpdateStatus).self) { group in
            func pump() {
                guard next < keys.count else { return }
                let key = keys[next]; next += 1
                let sample = byKey[key]!.first!
                group.addTask { (key, await checker.status(for: sample, force: force)) }
            }
            for _ in 0..<min(maxConcurrent, keys.count) { pump() }
            for await (key, status) in group {
                for s in byKey[key] ?? [] { statuses[s.id] = status }
                pump()
            }
        }
    }

    private static func order(_ a: Skill, _ b: Skill) -> Bool {
        if a.scope != b.scope { return a.scope == .global }   // global section first
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
