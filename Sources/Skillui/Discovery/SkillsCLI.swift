import Foundation

/// One row of `skills list --json`: `{name, path, scope, agents[]}` (verified shape).
struct CLISkill: Decodable, Sendable {
    let name: String
    let path: String
    let scope: String
    let agents: [String]
}

enum CLIError: Error, LocalizedError {
    case nonZero(Int32, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .nonZero(let s, let m): return "skills CLI exited \(s)\(m.isEmpty ? "" : ": \(m)")"
        case .decode(let m): return "Couldn't parse skills output: \(m)"
        }
    }
}

struct SkillsCLI: Sendable {
    let invocation: [String]   // e.g. ["/opt/homebrew/bin/npx","--yes","skills"]

    private var launchPath: String { invocation[0] }
    private var baseArgs: [String] { Array(invocation.dropFirst()) }

    /// `skills list -g|-p --json`. Default CLI scope is project, so we always pass a flag.
    func list(scope: Scope, cwd: String? = nil) async throws -> [CLISkill] {
        let r = await ProcessRunner.run(launchPath: launchPath,
                                        args: baseArgs + ["list", scope.cliFlag, "--json"],
                                        cwd: cwd, dropStderr: true)
        guard r.status == 0 else { throw CLIError.nonZero(r.status, r.stderrString) }
        // Clean JSON is the normal case; only fall back to slicing if that fails.
        if let skills = try? JSONDecoder().decode([CLISkill].self, from: r.stdout) { return skills }
        do { return try JSONDecoder().decode([CLISkill].self, from: Self.jsonSlice(r.stdout)) }
        catch { throw CLIError.decode(error.localizedDescription) }
    }

    /// `skills update <name> -g|-p -y`. Mutating — only call on user action.
    @discardableResult
    func update(name: String,
                scope: Scope,
                cwd: String? = nil,
                onOutput: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let args = baseArgs + ["update", name, scope.cliFlag, "-y"]
        let r: ProcessResult
        if let onOutput {
            r = await ProcessRunner.runStreaming(launchPath: launchPath,
                                                 args: args,
                                                 cwd: cwd,
                                                 onOutput: onOutput)
        } else {
            r = await ProcessRunner.run(launchPath: launchPath,
                                        args: args,
                                        cwd: cwd, dropStderr: false)
        }
        guard r.status == 0 else { throw CLIError.nonZero(r.status, r.combinedString) }
        return r.combinedString
    }

    /// `skills experimental_install -y` in `cwd` — hydrates a project/worktree's skills from its
    /// `skills-lock.json` (the same command `install-skills.sh` runs). Mutating; user action only.
    @discardableResult
    func installFromLock(cwd: String, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let args = baseArgs + ["experimental_install", "-y"]
        let r: ProcessResult
        if let onOutput {
            r = await ProcessRunner.runStreaming(launchPath: launchPath,
                                                 args: args,
                                                 cwd: cwd,
                                                 onOutput: onOutput)
        } else {
            r = await ProcessRunner.run(launchPath: launchPath,
                                        args: args,
                                        cwd: cwd, dropStderr: false)
        }
        guard r.status == 0 else { throw CLIError.nonZero(r.status, r.combinedString) }
        return r.combinedString
    }

    func updateCommand(name: String, scope: Scope, cwd: String? = nil) -> String {
        Self.describe(invocation + ["update", name, scope.cliFlag, "-y"], cwd: cwd)
    }

    func installFromLockCommand(cwd: String) -> String {
        Self.describe(invocation + ["experimental_install", "-y"], cwd: cwd)
    }

    /// Tolerate stray bytes around the JSON (e.g. a one-time npx install notice).
    static func jsonSlice(_ data: Data) -> Data {
        guard let start = data.firstIndex(of: UInt8(ascii: "[")),
              let end = data.lastIndex(of: UInt8(ascii: "]")), end >= start else { return data }
        return data.subdata(in: start..<(end + 1))
    }

    private static func describe(_ command: [String], cwd: String?) -> String {
        let rendered = command.map(shellQuote).joined(separator: " ")
        if let cwd { return "cd \(shellQuote(cwd))\n\(rendered)" }
        return rendered
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=.,/:@")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
