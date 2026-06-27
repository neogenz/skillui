import Foundation

/// Computes each skill's `UpdateStatus`.
///
/// Global locks carry `skillFolderHash`, a Git tree SHA, so they compare against GitHub's tree.
/// Project v1 locks carry `computedHash`, a skills-CLI SHA-256. Those hashes are not comparable
/// to Git tree SHAs; only root `SKILL.md` project skills can be checked exactly by hashing the
/// upstream file the same way the CLI does.
struct UpdateChecker: Sendable {
    let token: String?
    var cache: UpdateCacheStore? = nil

    private var gh: GitHubClient { GitHubClient(token: token) }

    /// Pure decision: compare the installed lock hash against the latest upstream hash.
    static func decide(installed: String, latest: String?) -> UpdateStatus {
        guard let latest else { return .failed("skill folder not found upstream") }
        return latest == installed ? .upToDate : .updateAvailable
    }

    /// Evaluate a batch. Returns skill.id → status (only for `canCheckUpdate` skills).
    /// Groups by (repo, ref) — one tree fetch per group — and runs groups concurrently
    /// (bounded), so hundreds of project skills resolve quickly instead of serially.
    func evaluate(_ skills: [Skill], ttl: TimeInterval = 6 * 3600, force: Bool = false) async -> [String: UpdateStatus] {
        var groups: [String: [Skill]] = [:]
        for s in skills where s.canCheckUpdate {
            groups["\(s.source!)\u{1}\(s.lock?.ref ?? "")", default: []].append(s)
        }
        let groupList = Array(groups.values)
        guard !groupList.isEmpty else { return [:] }

        var out: [String: UpdateStatus] = [:]
        let maxConcurrent = 6
        var next = 0
        await withTaskGroup(of: [String: UpdateStatus].self) { tg in
            func pump() {
                guard next < groupList.count else { return }
                let group = groupList[next]; next += 1
                tg.addTask { await self.evaluateGroup(group, ttl: ttl, force: force) }
            }
            for _ in 0..<min(maxConcurrent, groupList.count) { pump() }
            for await part in tg { out.merge(part) { _, new in new }; pump() }
        }
        return out
    }

    private func evaluateGroup(_ group: [Skill], ttl: TimeInterval, force: Bool) async -> [String: UpdateStatus] {
        var out: [String: UpdateStatus] = [:]
        let repo = group[0].source!
        let storedRef = group[0].lock?.ref.flatMap { $0.isEmpty ? nil : $0 }
        let tree = await treeMap(repo: repo, storedRef: storedRef, ttl: ttl, force: force)
        for s in group {
            switch tree {
            case .failed(let msg):
                out[s.id] = .failed(msg)
            case .ok(let map, let root, let ref):
                if let installed = s.lock?.skillFolderHash, !installed.isEmpty {
                    let folder = s.repoFolder ?? ""
                    let latest = folder.isEmpty ? root : map[folder]
                    out[s.id] = Self.decide(installed: installed, latest: latest)
                    continue
                }
                if let installed = s.lock?.computedHash,
                   let skillPath = s.lock?.skillPath,
                   s.repoFolder == "" {
                    let latest = await latestSingleFileHash(repo: repo, ref: ref, path: skillPath)
                    out[s.id] = Self.decide(installed: installed, latest: latest)
                    continue
                }
                out[s.id] = .unsupported
            }
        }
        return out
    }

    private func latestSingleFileHash(repo: String, ref: String, path: String) async -> String? {
        guard let data = try? await gh.fileContents(repo: repo, path: path, ref: ref) else { return nil }
        return SkillsContentHasher.singleFileHash(contents: data)
    }

    private enum TreeOutcome {
        case ok(map: [String: String], root: String?, ref: String)
        case failed(String)
    }

    private func treeMap(repo: String, storedRef: String?, ttl: TimeInterval, force: Bool) async -> TreeOutcome {
        let cacheKey = "\(repo)@\(storedRef ?? "")"

        let ref: String
        if let storedRef {
            ref = storedRef
        } else if let store = cache, let cached = await store.branch(repo) {
            ref = cached
        } else {
            do {
                let resolved = try await gh.defaultBranch(repo: repo)
                await cache?.setBranch(repo, resolved)
                ref = resolved
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        // Fresh-enough cache → no network.
        if !force, let store = cache, let e = await store.tree(cacheKey),
           Date().timeIntervalSince(e.checkedAt) < ttl {
            return .ok(map: e.folderSHAs, root: e.rootSHA, ref: ref)
        }

        do {
            let prior = await cache?.tree(cacheKey)
            let tm = try await gh.folderSHAMap(repo: repo, ref: ref, etag: prior?.etag)

            if tm.notModified, let prior {
                await cache?.setTree(cacheKey, .init(etag: prior.etag, folderSHAs: prior.folderSHAs,
                                                     rootSHA: prior.rootSHA, checkedAt: Date()))
                return .ok(map: prior.folderSHAs, root: prior.rootSHA, ref: ref)
            }
            await cache?.setTree(cacheKey, .init(etag: tm.etag, folderSHAs: tm.folderSHAs,
                                                 rootSHA: tm.rootSHA, checkedAt: Date()))
            return .ok(map: tm.folderSHAs, root: tm.rootSHA, ref: ref)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
