import Foundation

/// Classifies a skill install path as project-local vs a symlink into the global install.
enum LinkClassifier {
    /// Standard global skill roots (the symlink targets that mean "this is really the global skill").
    static func defaultGlobalRoots(customGlobalRoot: String?) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var roots = [
            "\(home)/.agents/skills",
            "\(home)/.claude/skills",
            "\(home)/.codex/skills",
            "\(home)/.cursor/skills",
        ]
        if let custom = customGlobalRoot, !custom.isEmpty {
            roots.insert((custom as NSString).expandingTildeInPath, at: 0)
        }
        // Resolve once so /var vs /private/var etc. compare cleanly.
        return roots.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    static func classify(path: String, scope: Scope, globalRoots: [String]) -> LinkType {
        if scope == .global { return .global }

        let url = URL(fileURLWithPath: path)
        let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        guard isSymlink else { return .projectLocal }

        // Resolve the symlink to its real location and see if it lives under a global root.
        let resolved = url.resolvingSymlinksInPath().path
        return globalRoots.contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
            ? .linkedGlobal : .linkedExternal
    }
}
