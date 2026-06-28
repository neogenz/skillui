import SwiftUI
import AppKit
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
    /// True when a token exists but macOS refused non-interactive Keychain access.
    var githubCredentialNeedsAttention = false
    var githubCredentialStatus: GitHubCredentialStatus = .unknown

    // Application self-update (GitHub Releases DMG)
    var appUpdateResult: AppUpdateResult?
    var isCheckingAppUpdate = false
    var isDownloadingAppUpdate = false
    var appUpdateWindowRevision = 0
    var hasScheduledAppUpdateCheck = false
    var lastDismissedAppUpdateVersion: String?

    // Recursive multi-project scan (Dashboard)
    var projectScanSkills: [Skill] = []
    var discoveredProjects: [String] = []
    var isScanningProjects = false
    var lastProjectScanAt: Date?
    /// Worktrees whose lockfile declares skills that aren't installed (fresh worktrees, etc.).
    var worktreeGaps: [WorktreeGap] = []
    /// Project roots currently running `skills experimental_install` (drives the install spinner).
    var installingPaths: Set<String> = []

    // User-visible update/install activity log.
    var updateActivity: UpdateActivitySession?
    var updateActivityWindowRevision = 0

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
    /// GitHub PAT entered during this run. Persist only through `saveGitHubPAT(_:)`.
    var githubPAT: String
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
    private static let maxActivityLogCharacters = 200_000
    private static let githubCredentialAttentionMessage = "GitHub token needs explicit Keychain authorization or replacement in Settings."
    /// Serial chain: refresh / updateSkill / updateAll run one at a time (never interleave
    /// at await points), so spinners, statuses and the rate limit stay consistent.
    private var tail: Task<Void, Never> = Task {}

    private enum GitHubCredential {
        /// `nil` is a deliberate unauthenticated GitHub request because no token is configured.
        case usable(String?)
        /// A token appears to exist, but macOS refused non-interactive access to it.
        case needsAttention(String)
    }

    enum GitHubCredentialStatus: Equatable {
        case unknown
        case configured
        case missing
        case needsAttention
    }

    private func serialize(_ op: @escaping @MainActor () async -> Void) async {
        let prev = tail
        let t = Task { @MainActor in await prev.value; await op() }
        tail = t
        await t.value
    }

    // MARK: Activation policy (Dock + app-switcher presence)
    // At rest the app is a menu-bar agent (.accessory). The Dashboard / Software Update / Update
    // Activity windows each need .regular so they pick up a Dock icon. Letting every scene flip the
    // policy on its own raced: closing one window demoted the whole app while another was still open,
    // and the Update Activity window never restored .accessory at all (leaving a stuck Dock icon).
    // Refcount the open "regular" windows instead — go .regular on 0→1, back to .accessory on 1→0.
    @ObservationIgnored private var regularWindowCount = 0

    /// Call from a regular window's `.onAppear`: bumps the refcount and ensures the app is foregrounded.
    func enterRegularActivation() {
        regularWindowCount += 1
        if regularWindowCount == 1 { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Call from a regular window's `.onDisappear`: only the last window standing demotes to .accessory.
    func leaveRegularActivation() {
        regularWindowCount = max(0, regularWindowCount - 1)
        if regularWindowCount == 0 { NSApp.setActivationPolicy(.accessory) }
    }

    /// All agent display names across discovered skills (for the Settings filter list).
    var allAgents: [String] { Array(Set(skills.flatMap(\.agents))).sorted() }

    /// Skills after per-agent visibility (hide skills whose agents are ALL hidden).
    var visibleSkills: [Skill] {
        guard !hiddenAgents.isEmpty else { return skills }
        return skills.filter { !$0.agents.allSatisfy(hiddenAgents.contains) }
    }

    var hasConfiguredGitHubCredential: Bool {
        if !githubPAT.isEmpty { return true }
        if case .configured = githubCredentialStatus { return true }
        return false
    }

    private func githubCredential() -> GitHubCredential {
        if !githubPAT.isEmpty {
            githubCredentialNeedsAttention = false
            githubCredentialStatus = .configured
            return .usable(githubPAT)
        }
        switch Keychain.readToken(allowInteraction: false) {
        case .success(let token):
            githubCredentialNeedsAttention = false
            githubCredentialStatus = .configured
            return .usable(token)
        case .notFound:
            githubCredentialNeedsAttention = false
            githubCredentialStatus = .missing
            return .usable(nil)
        case .interactionRequired, .failed:
            githubCredentialNeedsAttention = true
            githubCredentialStatus = .needsAttention
            return .needsAttention(Self.githubCredentialAttentionMessage)
        }
    }

    private func markGitHubCredentialAttention(_ candidates: [Skill]) {
        for s in candidates where s.canCheckUpdate {
            statuses[s.id] = .failed(Self.githubCredentialAttentionMessage)
        }
    }

    func refreshGitHubCredentialStatus() {
        if !githubPAT.isEmpty {
            githubCredentialNeedsAttention = false
            githubCredentialStatus = .configured
            return
        }
        switch Keychain.readToken(allowInteraction: false) {
        case .success:
            githubCredentialNeedsAttention = false
            githubCredentialStatus = .configured
        case .notFound:
            githubCredentialNeedsAttention = false
            githubCredentialStatus = .missing
        case .interactionRequired, .failed:
            githubCredentialNeedsAttention = true
            githubCredentialStatus = .needsAttention
        }
    }

    @discardableResult
    func saveGitHubPAT(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return clearGitHubPAT() }
        let status = Keychain.setToken(trimmed)
        guard status == errSecSuccess else {
            githubPAT = ""
            githubCredentialNeedsAttention = true
            githubCredentialStatus = .needsAttention
            return false
        }
        githubPAT = trimmed
        githubCredentialNeedsAttention = false
        githubCredentialStatus = .configured
        return true
    }

    @discardableResult
    func clearGitHubPAT() -> Bool {
        let status = Keychain.setToken(nil)
        githubPAT = ""
        guard status == errSecSuccess else {
            githubCredentialNeedsAttention = true
            githubCredentialStatus = .needsAttention
            return false
        }
        githubCredentialNeedsAttention = false
        githubCredentialStatus = .missing
        return true
    }

    @discardableResult
    func authorizeStoredGitHubPAT() -> Bool {
        switch Keychain.readToken(allowInteraction: true) {
        case .success(let token):
            githubPAT = token
            githubCredentialNeedsAttention = false
            githubCredentialStatus = .configured
            return true
        case .notFound:
            githubPAT = ""
            githubCredentialNeedsAttention = false
            githubCredentialStatus = .missing
            return true
        case .interactionRequired, .failed:
            githubPAT = ""
            githubCredentialNeedsAttention = true
            githubCredentialStatus = .needsAttention
            return false
        }
    }

    var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var releaseRepository: String {
        Bundle.main.object(forInfoDictionaryKey: "SkilluiReleaseRepository") as? String ?? "neogenz/skillui"
    }

    var availableAppRelease: AppRelease? {
        if case .available(let release) = appUpdateResult { return release }
        return nil
    }

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
        // Don't auto-refresh in the headless dev hooks (they drive their own scan + exit).
        let headless = CommandLine.arguments.contains { a in
            a.hasPrefix("--render") || a.hasPrefix("--scan") || a.hasPrefix("--login")
        }
        githubPAT = ""
        if !headless { startBackgroundRefresh() }
    }

    // MARK: Application updates

    func scheduleInitialAppUpdateCheck() {
        guard !hasScheduledAppUpdateCheck else { return }
        hasScheduledAppUpdateCheck = true
        Task { await checkForAppUpdate(manual: false) }
    }

    func checkForAppUpdate(manual: Bool, force: Bool = false) async {
        if isCheckingAppUpdate { return }
        isCheckingAppUpdate = true
        if manual {
            appUpdateResult = .checking
            presentAppUpdateWindow()
        }
        defer { isCheckingAppUpdate = false }

        let token: String?
        switch githubCredential() {
        case .usable(let resolvedToken):
            token = resolvedToken
        case .needsAttention(let message):
            if manual {
                appUpdateResult = .failed(message)
                presentAppUpdateWindow()
            }
            return
        }
        let checker = AppReleaseChecker(repository: releaseRepository, token: token)
        do {
            if let release = try await checker.latestUpdate(currentVersion: currentAppVersion) {
                appUpdateResult = .available(release)
                if manual || force || release.version != lastDismissedAppUpdateVersion {
                    presentAppUpdateWindow()
                }
            } else if manual {
                appUpdateResult = .upToDate(currentAppVersion)
                presentAppUpdateWindow()
            }
        } catch {
            if manual {
                appUpdateResult = .failed(error.localizedDescription)
                presentAppUpdateWindow()
            }
        }
    }

    func dismissAppUpdateForNow() {
        lastDismissedAppUpdateVersion = availableAppRelease?.version
        appUpdateResult = nil
    }

    func downloadAndOpenAppUpdate(_ release: AppRelease) async {
        guard let source = release.assetDownloadURL else {
            appUpdateResult = .failed("This release has no downloadable DMG asset.")
            presentAppUpdateWindow()
            return
        }
        if isDownloadingAppUpdate { return }
        isDownloadingAppUpdate = true
        defer { isDownloadingAppUpdate = false }
        do {
            let (temporaryURL, _) = try await URLSession.shared.download(from: source)
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            let destination = downloads.appendingPathComponent(release.assetName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            NSWorkspace.shared.open(destination)
        } catch {
            appUpdateResult = .failed("Download failed: \(error.localizedDescription)")
            presentAppUpdateWindow()
        }
    }

    private func presentAppUpdateWindow() {
        appUpdateWindowRevision += 1
    }

    func presentUpdateActivityWindow() {
        updateActivityWindowRevision += 1
    }

    @discardableResult
    private func beginUpdateActivity(title: String,
                                     subtitle: String,
                                     items: [UpdateActivityItem],
                                     autoOpen: Bool = true) -> [UUID] {
        updateActivity = UpdateActivitySession(title: title, subtitle: subtitle, items: items)
        if autoOpen { presentUpdateActivityWindow() }
        return items.map(\.id)
    }

    @discardableResult
    private func addActivityItem(title: String,
                                 subtitle: String = "",
                                 command: String? = nil,
                                 status: UpdateActivityStatus = .queued) -> UUID {
        let item = UpdateActivityItem(title: title, subtitle: subtitle, command: command, status: status)
        if updateActivity == nil {
            updateActivity = UpdateActivitySession(title: "Skill updates",
                                                   subtitle: "A mutating skills operation is running.",
                                                   items: [item])
            presentUpdateActivityWindow()
        } else {
            updateActivity?.finishedAt = nil
            updateActivity?.items.append(item)
        }
        return item.id
    }

    private func markActivityItem(_ id: UUID,
                                  status: UpdateActivityStatus,
                                  command: String? = nil,
                                  message: String? = nil) {
        guard let index = updateActivity?.items.firstIndex(where: { $0.id == id }) else { return }
        if updateActivity?.items[index].status != .running, status == .running {
            updateActivity?.items[index].startedAt = Date()
        }
        updateActivity?.items[index].status = status
        if status == .running { updateActivity?.finishedAt = nil }
        if let command { updateActivity?.items[index].command = command }
        if let message { appendActivityLog(id, message) }
        if status.isFinished { updateActivity?.items[index].finishedAt = Date() }
        finishActivityWhenSettled()
    }

    private func appendActivityLog(_ id: UUID, _ chunk: String) {
        guard !chunk.isEmpty,
              let index = updateActivity?.items.firstIndex(where: { $0.id == id }) else { return }
        var log = updateActivity?.items[index].log ?? ""
        log += chunk
        if !log.hasSuffix("\n") { log += "\n" }
        if log.count > Self.maxActivityLogCharacters {
            log = "[Earlier output truncated]\n" + String(log.suffix(Self.maxActivityLogCharacters))
        }
        updateActivity?.items[index].log = log
    }

    private func finishActivityWhenSettled() {
        guard let activity = updateActivity, activity.finishedAt == nil, !activity.items.isEmpty else { return }
        if activity.items.allSatisfy(\.status.isFinished) {
            updateActivity?.finishedAt = Date()
        }
    }

    private func activityOutputSink(_ id: UUID) -> @Sendable (String) -> Void {
        { chunk in Task { @MainActor in self.appendActivityLog(id, chunk) } }
    }

    private func activitySubtitle(for skill: Skill) -> String {
        var parts = [skill.scope.label.lowercased()]
        if let projectLabel = skill.projectLabel {
            parts.append(projectLabel)
        } else if let source = skill.source {
            parts.append(source)
        }
        return parts.joined(separator: " · ")
    }

    private func remainingUpdatableSkills(in targets: [Skill]) -> [Skill] {
        targets.filter { effectiveStatus(for: $0) == .updateAvailable }
    }

    private func finishRecheckActivity(_ id: UUID, targets: [Skill]) {
        let remaining = remainingUpdatableSkills(in: targets)
        if !remaining.isEmpty {
            let rows = remaining
                .sorted {
                    ($0.projectLabel ?? "", $0.name)
                        < ($1.projectLabel ?? "", $1.name)
                }
                .map { skill in
                    let location = skill.projectLabel ?? skill.source ?? skill.scope.label
                    return "- \(skill.name) (\(location))"
                }
                .joined(separator: "\n")
            markActivityItem(id, status: .warning,
                             message: """
                             \(remaining.count) skill\(remaining.count == 1 ? "" : "s") still differ from upstream after recheck:
                             \(rows)

                             The update command finished, then Skillui ran a fresh verification pass and these rows still compare as outdated.

                             Next step: open the Dashboard's Updates view and retry one listed row. If it remains listed after one retry, copy this log; that usually points to a lock/source mismatch in the skills CLI rather than a failed Skillui update.
                             """)
        } else if targets.contains(where: { $0.scope == .project && !$0.canCheckUpdate }) {
            markActivityItem(id, status: .succeeded,
                             message: """
                             Update status refreshed.

                             Some project-scope skills use the v1 project lock format without a reliable upstream hash. Skillui does not keep those rows in Updates after the CLI update completes, because comparing them to a Git tree can produce permanent false positives.
                             """)
        } else {
            markActivityItem(id, status: .succeeded, message: "Update status refreshed.")
        }
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

        // Prune statuses for skills that disappeared. `statuses` is SHARED with the dashboard's
        // project scan, so prune on the union of both surfaces — keying on `skills` alone would
        // delete every project-scan status (scanProjects uses this same union at its own prune).
        let liveIDs = Set((skills + projectScanSkills).map(\.id))
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
        // Project scan is NOT in the serial block so globals appear immediately while the (slower)
        // recursive walk runs in the background. It writes the SAME shared `statuses`/`skills`-adjacent
        // state, but only the disjoint project half of `statuses` — and scan()'s prune now keeps that
        // half intact (union prune above), so the two paths no longer clobber each other.
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
        let liveIDs = Set((skills + projectScanSkills).map(\.id))
        statuses = statuses.filter { liveIDs.contains($0.key) }

        // Flag projects whose lockfile declares skills that aren't on disk (a freshly-created
        // worktree never gets its skills hydrated) so the dashboard can offer to reinstall them.
        worktreeGaps = await Task.detached(priority: .utility) {
            Self.computeWorktreeGaps(projects: projects, installed: found)
        }.value

        // Evaluate update status for comparable project skills. Project v1 locks are only
        // checked when their hash can be compared to the upstream root SKILL.md exactly.
        for s in projectScanSkills where !s.canCheckUpdate { statuses[s.id] = .unsupported }
        let comparable = projectScanSkills.filter { $0.canCheckUpdate }
        if !comparable.isEmpty {
            for s in comparable where statuses[s.id] != .updateAvailable { statuses[s.id] = .checking }
            let token: String?
            switch githubCredential() {
            case .usable(let resolvedToken):
                token = resolvedToken
            case .needsAttention:
                markGitHubCredentialAttention(comparable)
                return
            }
            let checker = UpdateChecker(token: token, cache: cacheStore)
            let results = await checker.evaluate(comparable, force: force)
            for (id, st) in results { statuses[id] = st }
        }
    }

    /// Pure gap detection (runs off-main): a project is "incomplete" when its `skills-lock.json`
    /// names skills that the on-disk scan didn't find. Covers worktrees with zero installed skills
    /// too, since `ProjectFinder` lists any dir that has a lockfile.
    nonisolated static func computeWorktreeGaps(projects: [String], installed: [Skill]) -> [WorktreeGap] {
        let byPath = Dictionary(grouping: installed, by: { $0.projectPath ?? "" })
        var gaps: [WorktreeGap] = []
        for path in projects {
            let lock = LockfileParser.read(LockfileParser.projectLockURL(projectRoot: path))
            guard !lock.isEmpty else { continue }
            let have = Set((byPath[path] ?? []).map(\.name))
            let missing = lock.keys.filter { !have.contains($0) }.sorted()
            guard !missing.isEmpty else { continue }
            let meta = GitInfo.meta(for: path)
            gaps.append(WorktreeGap(path: path, name: meta.name, group: meta.mainRepo ?? meta.name,
                                    isWorktree: meta.isWorktree, missing: missing, expected: lock.count))
        }
        return gaps.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Hydrate one project/worktree's skills from its lockfile, then rescan so the gap clears and
    /// the restored skills appear. Serialized like the other mutating ops.
    func installMissingSkills(at path: String) async {
        await installMissingSkills(at: [path])
    }

    func installMissingSkills(at paths: [String]) async {
        let distinct = Array(Set(paths)).sorted()
            .filter { !installingPaths.contains($0) }
        guard !distinct.isEmpty else { return }
        for path in distinct { installingPaths.insert(path) }
        let items = distinct.map { path in
            UpdateActivityItem(title: "Install missing skills",
                               subtitle: (path as NSString).abbreviatingWithTildeInPath)
        }
        let itemIDs = beginUpdateActivity(
            title: distinct.count == 1 ? "Installing missing skills" : "Installing missing skills in \(distinct.count) worktrees",
            subtitle: "`skills experimental_install` is restoring project-scope skills from lockfiles.",
            items: items)

        await serialize {
            defer { self.installingPaths.subtract(distinct) }
            guard let invocation = await self.resolveCLI() else {
                for id in itemIDs {
                    self.markActivityItem(id, status: .failed, message: "Couldn't find `skills` or `npx`. Set a path in Settings.")
                }
                return
            }
            let cli = SkillsCLI(invocation: invocation)
            for (path, id) in zip(distinct, itemIDs) {
                self.markActivityItem(id, status: .running, command: cli.installFromLockCommand(cwd: path))
                do {
                    try await cli.installFromLock(cwd: path, onOutput: self.activityOutputSink(id))
                    self.markActivityItem(id, status: .succeeded, message: "Install completed.")
                } catch {
                    self.lastError = "Install failed for \((path as NSString).lastPathComponent): \(error.localizedDescription)"
                    self.markActivityItem(id, status: .failed, message: error.localizedDescription)
                }
            }
        }
        let scanID = addActivityItem(title: "Refresh project scan",
                                     subtitle: "Rebuilding the dashboard view after install.")
        markActivityItem(scanID, status: .running)
        await scanProjects(force: true)
        markActivityItem(scanID, status: .succeeded, message: "Project scan refreshed.")
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
        let itemID = beginUpdateActivity(
            title: "Updating \(skill.name)",
            subtitle: "`skills update` is running for one skill.",
            items: [UpdateActivityItem(title: "Update \(skill.name)",
                                       subtitle: activitySubtitle(for: skill))]
        )[0]
        await serialize {
            defer { self.updatingSkillIDs.remove(skill.id) }
            guard let invocation = await self.resolveCLI() else {
                self.markActivityItem(itemID, status: .failed, message: "Couldn't find `skills` or `npx`. Set a path in Settings.")
                return
            }
            let cli = SkillsCLI(invocation: invocation)
            self.markActivityItem(itemID, status: .running,
                                  command: cli.updateCommand(name: skill.name, scope: skill.scope, cwd: skill.projectPath))
            do {
                try await cli.update(name: skill.name,
                                     scope: skill.scope,
                                     cwd: skill.projectPath,
                                     onOutput: self.activityOutputSink(itemID))
                self.markActivityItem(itemID, status: .succeeded, message: "Update completed.")
                let scanID = self.addActivityItem(title: "Refresh skill index",
                                                  subtitle: "Rescanning installed skills after the update.")
                self.markActivityItem(scanID, status: .running)
                await self.scan()
                self.markActivityItem(scanID, status: .succeeded, message: "Skill index refreshed.")
                if skill.scope == .project {
                    let projectScanID = self.addActivityItem(title: "Refresh project scan",
                                                             subtitle: "Rescanning project-scope skills after the update.")
                    self.markActivityItem(projectScanID, status: .running)
                    await self.scanProjects(force: true)
                    self.markActivityItem(projectScanID, status: .succeeded, message: "Project scan refreshed.")
                }
                let checkID = self.addActivityItem(title: "Recheck update status",
                                                   subtitle: "Comparing local skill hashes with GitHub.")
                self.markActivityItem(checkID, status: .running)
                await self.checkUpdates(force: true)
                await self.reevaluateProjectStatuses([skill])
                self.finishRecheckActivity(checkID, targets: [skill])
            } catch {
                self.lastError = "Update failed for \(skill.name): \(error.localizedDescription)"
                self.markActivityItem(itemID, status: .failed, message: error.localizedDescription)
            }
        }
    }

    /// Re-evaluate update status for specific project-scope skills directly from their (now
    /// changed) on-disk folder. Used after an update instead of a full recursive project
    /// re-walk: the walk is slow — pinning the row spinner for its whole duration — and its
    /// `isScanningProjects` single-flight guard can silently drop a forced run while a
    /// background refresh / Rescan is mid-walk, leaving the just-updated badge stale.
    private func reevaluateProjectStatuses(_ candidates: [Skill]) async {
        for s in candidates where s.scope == .project && !s.canCheckUpdate { statuses[s.id] = .unsupported }
        let checkable = candidates.filter { $0.scope == .project && $0.canCheckUpdate }
        guard !checkable.isEmpty else { return }
        let token: String?
        switch githubCredential() {
        case .usable(let resolvedToken):
            token = resolvedToken
        case .needsAttention:
            markGitHubCredentialAttention(checkable)
            return
        }
        let checker = UpdateChecker(token: token, cache: cacheStore)
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
        let itemIDs = beginUpdateActivity(
            title: distinct.count == 1 ? "Updating 1 skill" : "Updating \(distinct.count) skills",
            subtitle: "`skills update` is applying available upstream changes.",
            items: distinct.map { skill in
                UpdateActivityItem(title: "Update \(skill.name)",
                                   subtitle: activitySubtitle(for: skill))
            }
        )
        await serialize {
            defer { self.updatingSkillIDs.subtract(ids) }
            guard let invocation = await self.resolveCLI() else {
                for id in itemIDs {
                    self.markActivityItem(id, status: .failed, message: "Couldn't find `skills` or `npx`. Set a path in Settings.")
                }
                return
            }
            let cli = SkillsCLI(invocation: invocation)
            // Gate on the live status: a per-row updateSkill that landed first may have already
            // cleared one of these, so re-running `skills update` on it would be redundant.
            for (t, itemID) in zip(distinct, itemIDs) {
                guard self.effectiveStatus(for: t) == .updateAvailable else {
                    self.markActivityItem(itemID, status: .skipped, message: "Already up to date by the time this batch reached it.")
                    continue
                }
                self.markActivityItem(itemID, status: .running,
                                      command: cli.updateCommand(name: t.name, scope: t.scope, cwd: t.projectPath))
                do {
                    try await cli.update(name: t.name,
                                         scope: t.scope,
                                         cwd: t.projectPath,
                                         onOutput: self.activityOutputSink(itemID))
                }
                catch {
                    self.lastError = "Update failed for \(t.name): \(error.localizedDescription)"
                    self.markActivityItem(itemID, status: .failed, message: error.localizedDescription)
                    continue
                }
                self.markActivityItem(itemID, status: .succeeded, message: "Update completed.")
            }
            let scanID = self.addActivityItem(title: "Refresh skill index",
                                              subtitle: "Rescanning installed skills after the batch.")
            self.markActivityItem(scanID, status: .running)
            await self.scan()
            self.markActivityItem(scanID, status: .succeeded, message: "Skill index refreshed.")
            if targets.contains(where: { $0.scope == .project }) {
                let projectScanID = self.addActivityItem(title: "Refresh project scan",
                                                         subtitle: "Rescanning project-scope skills after the batch.")
                self.markActivityItem(projectScanID, status: .running)
                await self.scanProjects(force: true)
                self.markActivityItem(projectScanID, status: .succeeded, message: "Project scan refreshed.")
            }
            let checkID = self.addActivityItem(title: "Recheck update status",
                                               subtitle: "Comparing local skill hashes with GitHub.")
            self.markActivityItem(checkID, status: .running)
            await self.checkUpdates(force: true)
            await self.reevaluateProjectStatuses(targets)
            self.finishRecheckActivity(checkID, targets: targets)
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

        let token: String?
        switch githubCredential() {
        case .usable(let resolvedToken):
            token = resolvedToken
        case .needsAttention:
            markGitHubCredentialAttention(checkable)
            return
        }
        let checker = UpdateChecker(token: token, cache: cacheStore)
        let results = await checker.evaluate(checkable, force: force)
        for (id, status) in results { statuses[id] = status }
    }

    private static func order(_ a: Skill, _ b: Skill) -> Bool {
        if a.scope != b.scope { return a.scope == .global }   // global section first
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
