import Foundation
import ServiceManagement

/// Headless verification hook (dev only). `Quiver --scan-dump` runs discovery without a
/// GUI and prints a summary, then exits. Runs entirely off the main actor so blocking the
/// main thread here can't deadlock. `--check` additionally runs update detection.
enum DebugCLI {
    static func runIfRequested() {
        let args = CommandLine.arguments

        // Login-item probes (must run from the .app bundle, not `swift run`).
        if args.contains("--login-status") {
            print("login status: \(label(SMAppService.mainApp.status))"); exit(0)
        }
        if args.contains("--login-register") {
            do { try SMAppService.mainApp.register(); print("registered: \(label(SMAppService.mainApp.status))") }
            catch { print("register error: \(error.localizedDescription)") }
            exit(0)
        }
        if args.contains("--login-unregister") {
            do { try SMAppService.mainApp.unregister(); print("unregistered: \(label(SMAppService.mainApp.status))") }
            catch { print("unregister error: \(error.localizedDescription)") }
            exit(0)
        }

        // Recursive multi-project scan probe: `--scan-projects [root]`.
        if let i = args.firstIndex(of: "--scan-projects") {
            let root = (i + 1 < args.count && !args[i + 1].hasPrefix("--"))
                ? args[i + 1] : FileManager.default.homeDirectoryForCurrentUser.path
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let globalRoots = LinkClassifier.defaultGlobalRoots(customGlobalRoot: nil)
                let projects = ProjectFinder(root: root).find()
                print("root: \(root)\nprojects found: \(projects.count)")
                for p in projects { print("  • \(p)") }
                let skills = FilesystemScanner(globalRoots: globalRoots).scan(projectRoots: projects)
                print("project skills: \(skills.count)")
                for s in skills.sorted(by: { $0.name < $1.name }) {
                    print("  [\(s.linkType.rawValue)] \(s.name)  src:\(s.source ?? "—")  proj:\(s.projectName ?? "-")  agents:\(s.agents.joined(separator: ","))")
                }
                sem.signal()
            }
            sem.wait()
            exit(0)
        }

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

            var statuses: [String: UpdateStatus] = [:]
            if withCheck {
                statuses = await UpdateChecker(token: nil).evaluate(outcome.skills)
            }
            for s in outcome.skills.sorted(by: { $0.name < $1.name }) {
                let v = s.shortVersion ?? "—"
                let src = s.source ?? "untracked"
                var line = "  [\(s.scope.rawValue)] \(s.name)  v:\(v)  src:\(src)  folder:\(s.repoFolder ?? "-")  agents:\(s.agents.count)"
                if let st = statuses[s.id] { line += "  → \(st)" }
                print(line)
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    }

    private static func label(_ s: SMAppService.Status) -> String {
        switch s {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }
}
