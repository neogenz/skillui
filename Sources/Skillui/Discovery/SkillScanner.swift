import Foundation

/// Orchestrates discovery: ask the CLI for installed skills (global + each configured
/// project), then join each row with its lockfile entry **by skill name** within scope.
/// Skills with no lock entry are kept but marked untracked (no source/version).
struct SkillScanner: Sendable {
    let cli: SkillsCLI
    let projectRoots: [String]
    var globalRoots: [String] = []   // for link-type classification of project skills

    struct Outcome: Sendable {
        var skills: [Skill]
        var error: String?
    }

    func scan() async -> Outcome {
        var result: [Skill] = []
        var firstError: String?

        // GLOBAL
        let globalLock = LockfileParser.read(LockfileParser.globalLockURL())
        do {
            for c in try await cli.list(scope: .global) {
                result.append(Skill(name: c.name, path: c.path, scope: .global,
                                    agents: c.agents, projectPath: nil, lock: globalLock[c.name]))
            }
        } catch {
            firstError = "Global scan failed: \(error.localizedDescription)"
        }

        // PROJECTS (user-added folders; the CLI can only list the cwd's project)
        for root in projectRoots {
            let projLock = LockfileParser.read(LockfileParser.projectLockURL(projectRoot: root))
            do {
                for c in try await cli.list(scope: .project, cwd: root) {
                    let link = LinkClassifier.classify(path: c.path, scope: .project, globalRoots: globalRoots)
                    result.append(Skill(name: c.name, path: c.path, scope: .project,
                                        agents: c.agents, projectPath: root, lock: projLock[c.name],
                                        linkType: link))
                }
            } catch {
                if firstError == nil {
                    firstError = "Project scan failed (\(root)): \(error.localizedDescription)"
                }
            }
        }

        return Outcome(skills: result, error: firstError)
    }
}
