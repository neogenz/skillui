import Foundation

enum ShellEnvironment {
    /// Resolve how to invoke the skills CLI, returning an argv prefix:
    ///   ["/path/skills"]                      — a bare `skills` binary on PATH, or
    ///   ["/path/npx", "--yes", "skills"]      — fallback via npx (the common case;
    ///                                            on this machine `skills` is not a
    ///                                            standalone binary, only `npx skills`).
    ///
    /// GUI apps do NOT inherit the user's shell PATH (nvm/Homebrew), so we ask a login
    /// shell to resolve the binaries. Returns nil if neither is found.
    static func resolveSkillsInvocation(override: String?) async -> [String]? {
        if let override, !override.isEmpty {
            let name = (override as NSString).lastPathComponent
            if name == "npx" { return [override, "--yes", "skills"] }
            return [override]   // assume a `skills` binary or compatible wrapper
        }
        let probe = await ProcessRunner.run(
            launchPath: "/bin/zsh",
            args: ["-lc", "command -v skills 2>/dev/null; printf '|'; command -v npx 2>/dev/null"],
            dropStderr: true
        )
        let parts = probe.stdoutString.components(separatedBy: "|")
        let skillsPath = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let npxPath = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if !skillsPath.isEmpty { return [skillsPath] }
        if !npxPath.isEmpty { return [npxPath, "--yes", "skills"] }
        return nil
    }
}
