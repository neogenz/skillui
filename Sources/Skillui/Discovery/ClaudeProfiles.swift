import Foundation

/// A Claude Code config profile: `~/.claude` ("default") or a `~/.claude-<name>` dir kept by
/// multi-account launchers. Each has its own `skills/`, which the skills CLI never sees (it only
/// knows `~/.claude/skills`), so membership is read straight from the filesystem.
struct ClaudeProfile: Sendable, Equatable {
    let name: String
    let skillsDir: String
    let skillNames: Set<String>
}

enum ClaudeProfiles {
    /// Profiles with a `skills/` dir, "default" first. A skill counts only if its `SKILL.md`
    /// resolves (follows symlinks, so dangling links into a cleaned-up store are ignored).
    static func discover(home: String = NSHomeDirectory()) -> [ClaudeProfile] {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(atPath: home)) ?? [])
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") }
            .sorted()   // ".claude" sorts before ".claude-*"
        return dirs.compactMap { dir in
            let skillsDir = (home as NSString).appendingPathComponent("\(dir)/skills")
            guard let entries = try? fm.contentsOfDirectory(atPath: skillsDir) else { return nil }
            let names = entries.filter {
                !$0.hasPrefix(".") && fm.fileExists(atPath: "\(skillsDir)/\($0)/SKILL.md")
            }
            let name = dir == ".claude" ? "default" : String(dir.dropFirst(".claude-".count))
            return ClaudeProfile(name: name, skillsDir: skillsDir, skillNames: Set(names))
        }
    }

    /// Tags each global skill with the profiles that have it, and appends skills that live only in
    /// profile dirs. Profile-only copies stay untracked: `skills update -g` never reaches them.
    /// No-op with fewer than two profiles (nothing to compare).
    static func merge(_ skills: [Skill], profiles: [ClaudeProfile]) -> [Skill] {
        guard profiles.count > 1 else { return skills }
        var result = skills.map { s -> Skill in
            guard s.scope == .global else { return s }
            var s = s
            s.profiles = profiles.filter { $0.skillNames.contains(s.name) }.map(\.name)
            return s
        }
        let known = Set(skills.filter { $0.scope == .global }.map(\.name))
        let extra = Set(profiles.flatMap(\.skillNames)).subtracting(known).sorted()
        for name in extra {
            let owners = profiles.filter { $0.skillNames.contains(name) }
            var s = Skill(name: name, path: "\(owners[0].skillsDir)/\(name)", scope: .global,
                          agents: ["Claude Code"], projectPath: nil, lock: nil)
            s.profiles = owners.map(\.name)
            result.append(s)
        }
        return result
    }
}
