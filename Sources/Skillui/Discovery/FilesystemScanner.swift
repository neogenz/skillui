import Foundation

/// Enumerates a project's skills directly from disk (fast, and gives the symlink info the
/// `skills list` CLI doesn't): for each skill it records which agent dirs hold it and whether
/// it's project-local or a symlink into the global install. Joins the project `skills-lock.json`
/// by name for source/version.
struct FilesystemScanner: Sendable {
    let globalRoots: [String]

    static let agentDirs: [(rel: String, label: String)] = [
        (".agents/skills", "Shared"),
        (".claude/skills", "Claude Code"),
        (".codex/skills", "Codex"),
        (".cursor/skills", "Cursor"),
    ]

    func scan(projectRoots: [String]) -> [Skill] {
        projectRoots.flatMap { scanProject($0) }
    }

    func scanProject(_ root: String) -> [Skill] {
        let fm = FileManager.default
        let lock = LockfileParser.read(LockfileParser.projectLockURL(projectRoot: root))
        let meta = GitInfo.meta(for: root)

        struct Acc { var canonicalPath: String; var agents: Set<String> }
        var byName: [String: Acc] = [:]

        for (rel, label) in Self.agentDirs {
            let dir = URL(fileURLWithPath: root).appendingPathComponent(rel)
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
            else { continue }
            for e in entries {
                let name = e.lastPathComponent
                if name.hasPrefix(".") { continue }
                let vals = try? e.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard vals?.isDirectory == true || vals?.isSymbolicLink == true else { continue }
                var acc = byName[name] ?? Acc(canonicalPath: e.path, agents: [])
                acc.agents.insert(label)
                if rel == ".agents/skills" { acc.canonicalPath = e.path }   // prefer the shared dir
                byName[name] = acc
            }
        }

        return byName.map { name, acc in
            let link = LinkClassifier.classify(path: acc.canonicalPath, scope: .project, globalRoots: globalRoots)
            return Skill(name: name, path: acc.canonicalPath, scope: .project,
                         agents: Array(acc.agents).sorted(), projectPath: root,
                         lock: lock[name], linkType: link,
                         projectGroup: meta.mainRepo ?? meta.name, isWorktree: meta.isWorktree,
                         localFileCount: Self.fileCountForSingleFileCheck(lock[name], link: link, path: acc.canonicalPath))
        }
        .sorted { $0.name < $1.name }
    }

    /// File count for the single-file gate, computed only for the skills that can use it — a
    /// project-local skill whose lock points at a root `SKILL.md`. Everything else returns `nil`
    /// (cheap: no walk for the common subfolder / linked / global cases).
    static func fileCountForSingleFileCheck(_ lock: LockEntry?, link: LinkType, path: String) -> Int? {
        guard link == .projectLocal, lock?.computedHash != nil, lock?.skillPath == "SKILL.md"
        else { return nil }
        return installedFileCount(at: path)
    }

    /// Counts the files in an installed skill folder the way the skills CLI's
    /// `computeSkillFolderHash` does — recursive, skipping `.git` and `node_modules`. A count of 1
    /// means the folder is a lone `SKILL.md`, so its `computedHash` equals `computeSingleFileSkillHash`.
    static func installedFileCount(at path: String) -> Int? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
              let en = fm.enumerator(at: URL(fileURLWithPath: path),
                                     includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                     options: [])
        else { return nil }
        var count = 0
        for case let url as URL in en {
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if vals?.isDirectory == true {
                let n = url.lastPathComponent
                if n == ".git" || n == "node_modules" { en.skipDescendants() }
            } else if vals?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }
}
