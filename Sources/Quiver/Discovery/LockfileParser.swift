import Foundation

/// Reads skills lockfiles. Tolerant of both verified on-disk schemas:
///   - GLOBAL `~/.agents/.skill-lock.json` (v3): rich, has `skillFolderHash` + `sourceUrl`.
///   - PROJECT `<root>/skills-lock.json` (v1): lean, has `computedHash`, no tree SHA.
/// Both are keyed maps `{ "skills": { "<name>": { … } } }`. Returns [name: LockEntry].
enum LockfileParser {

    static func globalLockURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_STATE_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
                .appendingPathComponent("skills", isDirectory: true)
                .appendingPathComponent(".skill-lock.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents", isDirectory: true)
            .appendingPathComponent(".skill-lock.json")
    }

    static func projectLockURL(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot).appendingPathComponent("skills-lock.json")
    }

    private struct RawLock: Decodable {
        let skills: [String: RawEntry]?
    }
    private struct RawEntry: Decodable {
        let source: String?
        let sourceUrl: String?
        let ref: String?
        let skillPath: String?
        let skillFolderHash: String?
        let computedHash: String?
        let pluginName: String?
    }

    static func read(_ url: URL) -> [String: LockEntry] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(RawLock.self, from: data),
              let skills = raw.skills else { return [:] }
        return skills.mapValues { e in
            LockEntry(source: e.source,
                      sourceURL: e.sourceUrl,
                      ref: e.ref,
                      skillPath: e.skillPath,
                      skillFolderHash: e.skillFolderHash,
                      computedHash: e.computedHash,
                      pluginName: e.pluginName)
        }
    }
}
