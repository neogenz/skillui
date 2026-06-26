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
        let data = Self.jsonSlice(r.stdout)
        do { return try JSONDecoder().decode([CLISkill].self, from: data) }
        catch { throw CLIError.decode(error.localizedDescription) }
    }

    /// `skills update <name> -g|-p -y`. Mutating — only call on user action.
    @discardableResult
    func update(name: String, scope: Scope, cwd: String? = nil) async throws -> String {
        let r = await ProcessRunner.run(launchPath: launchPath,
                                        args: baseArgs + ["update", name, scope.cliFlag, "-y"],
                                        cwd: cwd, dropStderr: false)
        guard r.status == 0 else { throw CLIError.nonZero(r.status, r.combinedString) }
        return r.combinedString
    }

    /// Tolerate stray bytes around the JSON (e.g. a one-time npx install notice).
    static func jsonSlice(_ data: Data) -> Data {
        guard let start = data.firstIndex(of: UInt8(ascii: "[")),
              let end = data.lastIndex(of: UInt8(ascii: "]")), end >= start else { return data }
        return data.subdata(in: start..<(end + 1))
    }
}
