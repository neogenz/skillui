import Testing
import Foundation
@testable import Quiver

private func tempDir() throws -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("quiver-scan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Test func projectFinderFindsMarkersAndExcludesHome() throws {
    let fm = FileManager.default
    let home = try tempDir()
    // Home holds a GLOBAL skills dir — it must NOT be reported as a project.
    try fm.createDirectory(at: home.appendingPathComponent(".claude/skills/apex"), withIntermediateDirectories: true)
    // A real sub-project with .agents/skills.
    let proj = home.appendingPathComponent("work/myproj")
    try fm.createDirectory(at: proj.appendingPathComponent(".agents/skills/foo"), withIntermediateDirectories: true)
    // A marker buried in a skip dir → must be ignored.
    try fm.createDirectory(at: home.appendingPathComponent("node_modules/.agents/skills"), withIntermediateDirectories: true)
    // Markers inside macOS-protected folders → must NEVER be entered (privacy).
    try fm.createDirectory(at: home.appendingPathComponent("Documents/secret/.agents/skills"), withIntermediateDirectories: true)
    try fm.createDirectory(at: home.appendingPathComponent("Music/.agents/skills"), withIntermediateDirectories: true)

    // Resolve /var → /private/var so the comparison isn't tripped by the temp-dir symlink.
    let found = ProjectFinder(root: home.path, homeOverrideForTesting: home.path).find()
        .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    let projResolved = proj.resolvingSymlinksInPath().path
    let homeResolved = home.resolvingSymlinksInPath().path
    #expect(found.contains(projResolved))
    #expect(!found.contains(homeResolved))                     // home excluded (was the dupe bug)
    #expect(!found.contains { $0.contains("node_modules") })   // skip honored
    #expect(!found.contains { $0.contains("/Documents") })     // protected folder never entered
    #expect(!found.contains { $0.contains("/Music") })         // protected folder never entered
}

@Test func projectFinderFindsAgentWorktrees() throws {
    let fm = FileManager.default
    let home = try tempDir()
    let proj = home.appendingPathComponent("work/repo")
    try fm.createDirectory(at: proj.appendingPathComponent(".agents/skills/foo"), withIntermediateDirectories: true)
    // A Claude Code worktree under .claude/worktrees: the general walk skips `.claude`, but this
    // must still be found — it's where freshly-created, un-hydrated worktrees live.
    let wt = proj.appendingPathComponent(".claude/worktrees/feature-x")
    try fm.createDirectory(at: wt, withIntermediateDirectories: true)
    try Data("{\"skills\":{}}".utf8).write(to: wt.appendingPathComponent("skills-lock.json"))

    let found = ProjectFinder(root: home.path, homeOverrideForTesting: home.path).find()
        .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    #expect(found.contains(proj.resolvingSymlinksInPath().path))
    #expect(found.contains(wt.resolvingSymlinksInPath().path))   // worktree under .claude/worktrees discovered
}

@Test func computeWorktreeGapsDetectsMissingLockedSkills() throws {
    let proj = try tempDir()
    // Lockfile declares two skills…
    try Data("{\"skills\":{\"alpha\":{},\"beta\":{}}}".utf8)
        .write(to: proj.appendingPathComponent("skills-lock.json"))
    // …but only "alpha" is installed on disk → "beta" is the gap.
    let alpha = Skill(name: "alpha", path: proj.appendingPathComponent(".agents/skills/alpha").path,
                      scope: .project, agents: ["Shared"], projectPath: proj.path)
    let gaps = AppState.computeWorktreeGaps(projects: [proj.path], installed: [alpha])
    #expect(gaps.count == 1)
    #expect(gaps.first?.missing == ["beta"])
    #expect(gaps.first?.expected == 2)
    #expect(gaps.first?.installedCount == 1)

    // With both installed, no gap is reported.
    let beta = Skill(name: "beta", path: proj.appendingPathComponent(".agents/skills/beta").path,
                     scope: .project, agents: ["Shared"], projectPath: proj.path)
    #expect(AppState.computeWorktreeGaps(projects: [proj.path], installed: [alpha, beta]).isEmpty)
}

@Test func linkClassifierDistinguishesLocalLinkedExternal() throws {
    let fm = FileManager.default
    let base = try tempDir()
    let globalRoot = base.appendingPathComponent("global/skills")
    try fm.createDirectory(at: globalRoot.appendingPathComponent("shared"), withIntermediateDirectories: true)
    let elsewhere = base.appendingPathComponent("elsewhere/thing")
    try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)

    let skillsDir = base.appendingPathComponent("proj/.agents/skills")
    try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
    let local = skillsDir.appendingPathComponent("local")
    try fm.createDirectory(at: local, withIntermediateDirectories: true)
    let linked = skillsDir.appendingPathComponent("shared")
    try fm.createSymbolicLink(at: linked, withDestinationURL: globalRoot.appendingPathComponent("shared"))
    let ext = skillsDir.appendingPathComponent("ext")
    try fm.createSymbolicLink(at: ext, withDestinationURL: elsewhere)

    let roots = [globalRoot.resolvingSymlinksInPath().path]
    #expect(LinkClassifier.classify(path: local.path, scope: .project, globalRoots: roots) == .projectLocal)
    #expect(LinkClassifier.classify(path: linked.path, scope: .project, globalRoots: roots) == .linkedGlobal)
    #expect(LinkClassifier.classify(path: ext.path, scope: .project, globalRoots: roots) == .linkedExternal)
    #expect(LinkClassifier.classify(path: local.path, scope: .global, globalRoots: roots) == .global)
}

@Test func filesystemScannerReportsLinkTypesAndJoinsLock() throws {
    let fm = FileManager.default
    let base = try tempDir()
    let globalRoot = base.appendingPathComponent("global/skills")
    try fm.createDirectory(at: globalRoot.appendingPathComponent("find-skills"), withIntermediateDirectories: true)

    let proj = base.appendingPathComponent("proj")
    let agents = proj.appendingPathComponent(".agents/skills")
    try fm.createDirectory(at: agents.appendingPathComponent("local-skill"), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: agents.appendingPathComponent("find-skills"),
                              withDestinationURL: globalRoot.appendingPathComponent("find-skills"))
    let lockJSON = #"{ "version":1, "skills": { "local-skill": { "source":"me/repo", "skillPath":"skills/local-skill/SKILL.md", "computedHash":"abc" } } }"#
    try lockJSON.write(to: proj.appendingPathComponent("skills-lock.json"), atomically: true, encoding: .utf8)

    let roots = [globalRoot.resolvingSymlinksInPath().path]
    let skills = FilesystemScanner(globalRoots: roots).scanProject(proj.path)
    let byName = Dictionary(uniqueKeysWithValues: skills.map { ($0.name, $0) })
    #expect(byName["local-skill"]?.linkType == .projectLocal)
    #expect(byName["local-skill"]?.source == "me/repo")
    #expect(byName["find-skills"]?.linkType == .linkedGlobal)
    #expect(skills.allSatisfy { $0.scope == .project })
}

@Test func gitInfoDetectsWorktreeAndMainRepo() throws {
    let fm = FileManager.default
    let base = try tempDir()
    // Normal repo: .git is a directory.
    let main = base.appendingPathComponent("mainrepo")
    try fm.createDirectory(at: main.appendingPathComponent(".git"), withIntermediateDirectories: true)
    #expect(GitInfo.meta(for: main.path).isWorktree == false)

    // Worktree: .git is a file pointing into <main>/.git/worktrees/<wt>.
    let wt = base.appendingPathComponent("marseille")
    try fm.createDirectory(at: wt, withIntermediateDirectories: true)
    try "gitdir: /Users/x/pulpe-workspace/.git/worktrees/marseille\n"
        .write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    let w = GitInfo.meta(for: wt.path)
    #expect(w.isWorktree)
    #expect(w.mainRepo == "pulpe-workspace")
}

@Test func gitTreeHasherIsDeterministicAndDetectsChange() throws {
    let fm = FileManager.default
    let dir = try tempDir()
    try "hello".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try "world".write(to: dir.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)

    let sha1 = GitTreeHasher.treeSHA(dir)
    #expect(sha1?.count == 40)                                  // 40-hex git tree SHA
    #expect(GitTreeHasher.treeSHA(dir) == sha1)                 // deterministic

    let sigBefore = GitTreeHasher.signature(dir)
    try "changed".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    #expect(GitTreeHasher.treeSHA(dir) != sha1)                 // content change → different SHA
    #expect(GitTreeHasher.signature(dir) != sigBefore)         // and signature invalidates
}

@Test func projectLocalSkillIsUpdateCheckable() {
    // computedHash-only, but a real local folder → checkable (we compute the tree SHA on disk).
    let lock = LockEntry(source: "me/repo", skillPath: "skills/x/SKILL.md", computedHash: "deadbeef")
    let local = Skill(name: "x", path: "/p/.agents/skills/x", scope: .project,
                      agents: ["Shared"], projectPath: "/p", lock: lock, linkType: .projectLocal)
    #expect(local.canCheckUpdate)
    // same lock but a symlink elsewhere → not checkable
    let external = Skill(name: "x", path: "/p/.agents/skills/x", scope: .project,
                         agents: ["Shared"], projectPath: "/p", lock: lock, linkType: .linkedExternal)
    #expect(!external.canCheckUpdate)
}

@Test func skillProjectLabelShowsWorktreeUnderMainRepo() {
    let s = Skill(name: "x", path: "/p/marseille/.agents/skills/x", scope: .project,
                  agents: ["Shared"], projectPath: "/p/marseille", lock: nil,
                  linkType: .projectLocal, projectGroup: "pulpe-workspace", isWorktree: true)
    #expect(s.projectLabel == "pulpe-workspace › marseille")
}
