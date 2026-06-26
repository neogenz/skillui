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
    var lastError: String?
    var cliMissing = false

    // MARK: Settings (persisted to UserDefaults)

    var cliPathOverride: String {
        didSet { defaults.set(cliPathOverride, forKey: K.cliPath); cachedInvocation = nil }
    }
    var projectRoots: [String] {
        didSet { defaults.set(projectRoots, forKey: K.projectRoots) }
    }

    private let defaults = UserDefaults.standard
    private enum K {
        static let cliPath = "cliPathOverride"
        static let projectRoots = "projectRoots"
    }
    private var cachedInvocation: [String]?
    private let cacheStore = UpdateCacheStore()

    /// GitHub PAT for higher rate limits. Group F wires this to the Keychain; nil = unauthenticated.
    private func githubToken() -> String? { nil }

    init() {
        cliPathOverride = defaults.string(forKey: K.cliPath) ?? ""
        projectRoots = defaults.stringArray(forKey: K.projectRoots) ?? []
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
