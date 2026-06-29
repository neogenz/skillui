import Foundation

/// How to launch the skills CLI: the argv prefix plus the login-shell `PATH` it needs.
///
/// The `PATH` matters because `npx` is `#!/usr/bin/env node` — without `node`'s directory
/// on `PATH` the child dies with `env: node: No such file or directory`. GUI apps inherit
/// only launchd's stripped `PATH`, so we carry the login shell's `PATH` forward to the child.
struct ResolvedCLI: Sendable {
    let argv: [String]   // e.g. ["/opt/homebrew/bin/npx","--yes","skills"]
    let loginPath: String?   // login-shell $PATH, or nil when resolved from an override
}

enum ShellEnvironment {
    /// Resolve how to invoke the skills CLI, returning an argv prefix:
    ///   ["/path/skills"]                      — a bare `skills` binary on PATH, or
    ///   ["/path/npx", "--yes", "skills"]      — fallback via npx (the common case;
    ///                                            on this machine `skills` is not a
    ///                                            standalone binary, only `npx skills`).
    ///
    /// GUI apps do NOT inherit the user's shell PATH (nvm/Homebrew), so we ask a login
    /// shell to resolve the binaries *and* report its PATH. Returns nil if neither is found.
    static func resolveSkillsInvocation(override: String?) async -> ResolvedCLI? {
        if let override, !override.isEmpty {
            let name = (override as NSString).lastPathComponent
            if name == "npx" { return ResolvedCLI(argv: [override, "--yes", "skills"], loginPath: nil) }
            return ResolvedCLI(argv: [override], loginPath: nil)   // a `skills` binary or compatible wrapper
        }
        let probe = await ProcessRunner.run(
            launchPath: "/bin/zsh",
            args: ["-lc", "command -v skills 2>/dev/null; printf '|'; command -v npx 2>/dev/null; printf '|'; printf '%s' \"$PATH\""],
            dropStderr: true
        )
        let parts = probe.stdoutString.components(separatedBy: "|")
        let skillsPath = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let npxPath = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let loginPath = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let path = loginPath.isEmpty ? nil : loginPath
        if !skillsPath.isEmpty { return ResolvedCLI(argv: [skillsPath], loginPath: path) }
        if !npxPath.isEmpty { return ResolvedCLI(argv: [npxPath, "--yes", "skills"], loginPath: path) }
        return nil
    }
}
