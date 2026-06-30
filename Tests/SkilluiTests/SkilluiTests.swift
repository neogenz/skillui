import Testing
import Foundation
@testable import Skillui

// MARK: - Lockfile path resolution

@Test func globalLockPathResolves() {
    let url = LockfileParser.globalLockURL()
    if let xdg = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !xdg.isEmpty {
        #expect(url.path.hasPrefix(xdg))
        #expect(url.lastPathComponent == ".skill-lock.json")
    } else {
        #expect(url.path.hasSuffix("/.agents/.skill-lock.json"))
    }
}

@Test func projectLockPathResolves() {
    let url = LockfileParser.projectLockURL(projectRoot: "/Users/me/proj")
    #expect(url.path == "/Users/me/proj/skills-lock.json")
}

// MARK: - Lockfile parsing (both verified schemas)

private func writeTempLock(_ json: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("skillui-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("lock.json")
    try json.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func parsesGlobalV3Schema() throws {
    let url = try writeTempLock(#"""
    { "version": 3, "skills": {
        "find-skills": {
          "source": "vercel-labs/skills", "sourceType": "github",
          "sourceUrl": "https://github.com/vercel-labs/skills.git",
          "skillPath": "skills/find-skills/SKILL.md",
          "skillFolderHash": "3013fdeb8a11b10b1eb795ec3ae8bfca38f7c26d",
          "installedAt": "2026-02-03T10:32:48.963Z", "updatedAt": "2026-03-14T08:17:20.855Z"
        }
    }, "dismissed": {} }
    """#)
    let entries = LockfileParser.read(url)
    let e = try #require(entries["find-skills"])
    #expect(e.source == "vercel-labs/skills")
    #expect(e.sourceURL == "https://github.com/vercel-labs/skills.git")
    #expect(e.skillPath == "skills/find-skills/SKILL.md")
    #expect(e.skillFolderHash == "3013fdeb8a11b10b1eb795ec3ae8bfca38f7c26d")
    #expect(e.computedHash == nil)
}

@Test func parsesProjectV1Schema() throws {
    let url = try writeTempLock(#"""
    { "version": 1, "skills": {
        "claude-api": {
          "source": "anthropics/skills", "sourceType": "github",
          "skillPath": "skills/claude-api/SKILL.md",
          "computedHash": "9f19be17e56542510e93d2943227c776ecbbe978307fc43d660dd04b346ef395"
        }
    } }
    """#)
    let entries = LockfileParser.read(url)
    let e = try #require(entries["claude-api"])
    #expect(e.source == "anthropics/skills")
    #expect(e.computedHash?.hasPrefix("9f19be17") == true)
    #expect(e.skillFolderHash == nil)   // v1 has no git tree SHA
    #expect(e.sourceURL == nil)
}

@Test func toleratesMissingAndMalformedLock() throws {
    #expect(LockfileParser.read(URL(fileURLWithPath: "/nope/missing.json")).isEmpty)
    let bad = try writeTempLock("{ not json")
    #expect(LockfileParser.read(bad).isEmpty)
}

// MARK: - Skill model (join + derived links + update eligibility)

@Test func trackedGlobalSkillDerivesEverything() {
    let lock = LockEntry(source: "vercel-labs/skills",
                         sourceURL: "https://github.com/vercel-labs/skills.git",
                         skillPath: "skills/find-skills/SKILL.md",
                         skillFolderHash: "3013fdeb8a11b10b1eb795ec3ae8bfca38f7c26d")
    let s = Skill(name: "find-skills", path: "/x", scope: .global,
                  agents: ["Claude Code", "Cursor"], projectPath: nil, lock: lock)
    #expect(s.isTracked)
    #expect(s.canCheckUpdate)                                   // has tree SHA
    #expect(s.repoFolder == "skills/find-skills")              // dirname of SKILL.md
    #expect(s.githubURL?.absoluteString == "https://github.com/vercel-labs/skills") // .git stripped
    #expect(s.skillsShURL?.absoluteString == "https://skills.sh/vercel-labs/skills")
    #expect(s.shortVersion == "3013fde")
    #expect(s.updateKey == "vercel-labs/skills@::skills/find-skills")
}

@Test func projectComputedHashSkillIsNotUpdateCheckable() {
    let lock = LockEntry(source: "anthropics/skills",
                         skillPath: "skills/claude-api/SKILL.md",
                         computedHash: "9f19be17deadbeef")
    let s = Skill(name: "claude-api", path: "/x", scope: .project,
                  agents: ["Codex"], projectPath: "/proj", lock: lock)
    #expect(s.isTracked)
    #expect(!s.canCheckUpdate)                 // no git tree SHA
    #expect(s.installedSha == "9f19be17deadbeef")
    #expect(s.shortVersion == "9f19be1")
}

@Test func rootLevelSkillIsUpdateCheckable() {
    // A SKILL.md at the repo root → folder "" (the root tree), still checkable.
    let lock = LockEntry(source: "owner/repo", skillPath: "SKILL.md",
                         skillFolderHash: "abcdef0123456789")
    let s = Skill(name: "root-skill", path: "/x", scope: .global,
                  agents: ["Claude Code"], projectPath: nil, lock: lock)
    #expect(s.repoFolder == "")
    #expect(s.canCheckUpdate)
    #expect(s.updateKey == "owner/repo@::")
}

@Test func untrackedSkillHasNoProvenance() {
    let s = Skill(name: "apex", path: "/x", scope: .global,
                  agents: ["Claude Code"], projectPath: nil, lock: nil)
    #expect(!s.isTracked)
    #expect(!s.canCheckUpdate)
    #expect(s.source == nil)
    #expect(s.shortVersion == nil)
    #expect(s.skillsShURL?.absoluteString == "https://skills.sh")  // graceful fallback
}

// MARK: - Update decision (SHA comparison)

@Test func decideComparesFolderSHAs() {
    #expect(UpdateChecker.decide(installed: "abc123", latest: "abc123") == .upToDate)
    #expect(UpdateChecker.decide(installed: "abc123", latest: "def456") == .updateAvailable)
    if case .failed = UpdateChecker.decide(installed: "abc123", latest: nil) {} else {
        Issue.record("nil latest should be .failed")
    }
}

@Test func skillsContentHasherMatchesSingleFileProjectLock() {
    let hash = SkillsContentHasher.singleFileHash(contents: Data("hello".utf8))
    #expect(hash == "15ee0148f7664b9a5220aef539c3b4f54947ff5f5b5a0779ac39a90546117982")
}

// MARK: - App release version parsing

@Test func appReleaseVersionParsingStripsLeadingV() {
    #expect(AppReleaseChecker.versionString(from: "v0.2.0") == "0.2.0")
    #expect(AppReleaseChecker.versionString(from: "0.2.0-beta.1") == "0.2.0-beta.1")
}

@Test func appReleaseAssetSelectionAcceptsOnlyDMG() {
    #expect(AppReleaseChecker.isDMGAssetName("Skillui-0.2.0.dmg"))
    #expect(!AppReleaseChecker.isDMGAssetName("Skillui-0.2.0.dmg.sha256"))
    #expect(!AppReleaseChecker.isDMGAssetName("latest.json"))
}

@Test func appReleaseVersionComparisonHandlesSemanticSegments() {
    #expect(AppReleaseChecker.compareVersions("0.2.0", "0.1.9") == .orderedDescending)
    #expect(AppReleaseChecker.compareVersions("0.2.0", "0.2") == .orderedSame)
    #expect(AppReleaseChecker.compareVersions("0.2.0-beta.1", "0.2.0") == .orderedAscending)
    #expect(AppReleaseChecker.compareVersions("1.0.0", "1.0.0-beta.4") == .orderedDescending)
}

// MARK: - GitHub tree parsing (find the folder entry)

@Test func findsFolderTreeEntryBySHA() throws {
    let json = #"""
    { "truncated": false, "tree": [
        { "path": "skills/find-skills", "type": "tree", "sha": "eb6a23305aea6e340d14b9de3766e721f9f4861b" },
        { "path": "skills/find-skills/SKILL.md", "type": "blob", "sha": "deadbeef" }
    ] }
    """#
    let tree = try JSONDecoder().decode(GitHubClient.TreeResponse.self, from: Data(json.utf8))
    #expect(tree.truncated == false)
    let entry = tree.tree?.first { $0.path == "skills/find-skills" && $0.type == "tree" }
    #expect(entry?.sha == "eb6a23305aea6e340d14b9de3766e721f9f4861b")
}

// MARK: - CLI list parsing + noise tolerance

@Test func decodesListJSONAndTolaratesNoise() throws {
    let noisy = "npm notice installing…\n[{\"name\":\"x\",\"path\":\"/p\",\"scope\":\"global\",\"agents\":[\"Claude Code\"]}]\n".data(using: .utf8)!
    let sliced = SkillsCLI.jsonSlice(noisy)
    let skills = try JSONDecoder().decode([CLISkill].self, from: sliced)
    #expect(skills.count == 1)
    #expect(skills.first?.name == "x")
    #expect(skills.first?.agents == ["Claude Code"])
}

@Test func skillsCLICommandsAreShellReadable() {
    let cli = SkillsCLI(invocation: ["/usr/bin/npx", "--yes", "skills"])
    #expect(cli.updateCommand(name: "impeccable", scope: .global)
        == "/usr/bin/npx --yes skills update impeccable -g -y")
    #expect(cli.updateCommand(name: "ui kit", scope: .project, cwd: "/tmp/My Project")
        == "cd '/tmp/My Project'\n/usr/bin/npx --yes skills update 'ui kit' -p -y")
    #expect(cli.installFromLockCommand(cwd: "/tmp/Project's Worktree")
        == "cd '/tmp/Project'\\''s Worktree'\n/usr/bin/npx --yes skills experimental_install -y")
    // Per-source convergent install: space-separated skills, project + universal-agent defaults.
    #expect(cli.addSkillsCommand(package: "owner/repo", skills: ["a", "b"], cwd: "/tmp/My Project")
        == "cd '/tmp/My Project'\n/usr/bin/npx --yes skills add owner/repo -s a b -y")
}

@Test func updateActivityCombinedLogIncludesCommandsAndEmptyOutput() {
    let first = UpdateActivityItem(title: "Update impeccable",
                                   command: "npx skills update impeccable -g -y",
                                   status: .succeeded,
                                   log: "Done.\n")
    let second = UpdateActivityItem(title: "Recheck update status", status: .queued)
    let activity = UpdateActivitySession(title: "Updating 1 skill",
                                         subtitle: "Testing",
                                         items: [first, second])
    #expect(activity.completedCount == 1)
    #expect(activity.combinedLog.contains("## Update impeccable [Done]"))
    #expect(activity.combinedLog.contains("$ npx skills update impeccable -g -y"))
    #expect(activity.combinedLog.contains("## Recheck update status [Queued]"))
    #expect(activity.combinedLog.contains("(no output)"))
}

@Test func updateActivityWarningIsFinishedButNotSuccessful() {
    let item = UpdateActivityItem(title: "Recheck update status",
                                  status: .warning,
                                  log: "2 skills still differ from upstream after recheck.")
    let activity = UpdateActivitySession(title: "Updating 2 skills",
                                         subtitle: "Testing",
                                         items: [item])
    #expect(item.status.isFinished)
    #expect(activity.completedCount == 1)
    #expect(activity.warningCount == 1)
    #expect(activity.failedCount == 0)
    #expect(activity.combinedLog.contains("[Attention]"))
}

@Test func terminalLogCollapsesSpinnerRepaintsAndStripsAnsi() {
    let esc = "\u{1B}"
    // The exact shape `skills experimental_install` streams: a hidden cursor, then one line repainted
    // with ESC[999D (cursor home) + ESC[J (erase) between spinner frames, ending on the final message.
    let raw = """
    \(esc)[?25l│
    \(esc)[999D\(esc)[J◒  Cloning repository\(esc)[999D\(esc)[J◐  Cloning repository.\(esc)[999D\(esc)[J◓  Cloning repository..\(esc)[999D\(esc)[J◇  Repository cloned
    \(esc)[?25h│
    """
    let cleaned = TerminalLog.clean(raw)
    #expect(!cleaned.contains("[999D"))           // control codes gone
    #expect(!cleaned.contains("[J"))
    #expect(!cleaned.contains("[?25"))
    #expect(cleaned.contains("◇  Repository cloned"))
    // The repainted line collapses to a single rendered frame, not one line per spinner tick.
    #expect(cleaned.components(separatedBy: "Cloning repository").count - 1 <= 1)
    // Idempotent: re-cleaning an already-clean log is a no-op (the streaming sink relies on this).
    #expect(TerminalLog.clean(cleaned) == cleaned)
}

@Test func terminalLogExtractsConciseFailureReason() {
    // The exact failure block `skills experimental_install` emits when a lockfile source isn't a
    // cloneable git repo. The summary must name the source + reason, stripped of box glyphs, and must
    // NOT be the whole dump.
    let raw = """
    ●   claude-code_agent  Agent detected — installing non-interactively
    ◇  Source: likec4.dev
    ■  Failed to clone repository
    │  Failed to clone likec4.dev: fatal: repository 'likec4.dev' does not exist
    └  Installation failed
    ■  Canceled
    """
    let summary = TerminalLog.failureSummary(raw)
    #expect(summary == "Failed to clone likec4.dev: fatal: repository 'likec4.dev' does not exist")
    #expect(TerminalLog.failureSummary("all good\nInstalled 3 skills\nDone!") == nil)
}

@Test func terminalLogFoldsConsecutiveDuplicateLines() {
    // `experimental_install` echoes the same install path once per target agent (≈17×). Fold to one.
    let raw = "✓ angular-di (copied)\n→ /skills/angular-di\n→ /skills/angular-di\n→ /skills/angular-di\n"
    let cleaned = TerminalLog.clean(raw)
    #expect(cleaned.components(separatedBy: "→ /skills/angular-di").count - 1 == 1)
    #expect(cleaned.contains("✓ angular-di (copied)"))
}
