import Foundation

/// Headless verification hook (dev only). `Quiver --scan-dump` runs discovery without a
/// GUI and prints a summary, then exits. Runs entirely off the main actor so blocking the
/// main thread here can't deadlock. `--check` additionally runs update detection.
enum DebugCLI {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--scan-dump") else { return }
        let withCheck = args.contains("--check")

        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            guard let invocation = await ShellEnvironment.resolveSkillsInvocation(override: nil) else {
                print("CLI: not found (no `skills`/`npx` on login PATH)")
                sem.signal(); return
            }
            print("CLI: \(invocation.joined(separator: " "))")
            let scanner = SkillScanner(cli: SkillsCLI(invocation: invocation), projectRoots: [])
            let outcome = await scanner.scan()
            print("skills: \(outcome.skills.count)  error: \(outcome.error ?? "none")\n")

            let checker = withCheck ? UpdateChecker(token: nil) : nil
            for s in outcome.skills.sorted(by: { $0.name < $1.name }) {
                let v = s.shortVersion ?? "—"
                let src = s.source ?? "untracked"
                var line = "  [\(s.scope.rawValue)] \(s.name)  v:\(v)  src:\(src)  folder:\(s.repoFolder ?? "-")  agents:\(s.agents.count)"
                if let checker, s.canCheckUpdate {
                    line += "  → \(await checker.status(for: s))"
                }
                print(line)
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
}
