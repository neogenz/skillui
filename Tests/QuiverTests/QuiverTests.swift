import Testing
import Foundation
@testable import Quiver

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
        .appendingPathComponent("quiver-tests-\(UUID().uuidString)", isDirectory: true)
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
