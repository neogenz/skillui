import Foundation

/// Computes each skill's `UpdateStatus` by comparing its installed folder tree SHA against
/// the upstream one. Skills are grouped by (repo, ref) so we make ONE tree request per repo
/// (covering all its folders) and resolve the default branch once. The installed SHA is
/// per-skill, so the verdict is decided per skill — never shared across folders sharing a repo.
struct UpdateChecker: Sendable {
    let token: String?
    var cache: UpdateCacheStore? = nil

    private var gh: GitHubClient { GitHubClient(token: token) }

    /// Pure decision: compare installed folder tree SHA against the latest upstream one.
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
            case .ok(let map, let root):
                guard let installed = await installedTreeSHA(for: s) else { out[s.id] = .unsupported; continue }
                let folder = s.repoFolder ?? ""
                let latest = folder.isEmpty ? root : map[folder]
                out[s.id] = Self.decide(installed: installed, latest: latest)
            }
        }
        return out
    }

    /// Installed folder tree SHA: the lockfile's git tree SHA if present (global), else the
    /// git tree SHA computed from the local folder (project-local), cached by signature.
    private func installedTreeSHA(for s: Skill) async -> String? {
        if let h = s.lock?.skillFolderHash, !h.isEmpty { return h }
        guard s.linkType == .projectLocal else { return nil }
        let url = URL(fileURLWithPath: s.path)
        let sig = GitTreeHasher.signature(url)
        if let cached = await cache?.localTree(s.path), cached.signature == sig { return cached.sha }
        guard let sha = GitTreeHasher.treeSHA(url) else { return nil }
        await cache?.setLocalTree(s.path, .init(signature: sig, sha: sha))
        return sha
    }

    private enum TreeOutcome {
        case ok(map: [String: String], root: String?)
        case failed(String)
    }

    private func treeMap(repo: String, storedRef: String?, ttl: TimeInterval, force: Bool) async -> TreeOutcome {
        let cacheKey = "\(repo)@\(storedRef ?? "")"

        // Fresh-enough cache → no network.
        if !force, let store = cache, let e = await store.tree(cacheKey),
           Date().timeIntervalSince(e.checkedAt) < ttl {
            return .ok(map: e.folderSHAs, root: e.rootSHA)
        }

        do {
            // Resolve ref once (cache the default branch — lockfiles usually omit `ref`).
            let ref: String
            if let storedRef {
                ref = storedRef
            } else if let store = cache, let cached = await store.branch(repo) {
                ref = cached
            } else {
                let resolved = try await gh.defaultBranch(repo: repo)
                await cache?.setBranch(repo, resolved)
                ref = resolved
            }

            let prior = await cache?.tree(cacheKey)
            let tm = try await gh.folderSHAMap(repo: repo, ref: ref, etag: prior?.etag)

            if tm.notModified, let prior {
                await cache?.setTree(cacheKey, .init(etag: prior.etag, folderSHAs: prior.folderSHAs,
                                                     rootSHA: prior.rootSHA, checkedAt: Date()))
                return .ok(map: prior.folderSHAs, root: prior.rootSHA)
            }
            await cache?.setTree(cacheKey, .init(etag: tm.etag, folderSHAs: tm.folderSHAs,
                                                 rootSHA: tm.rootSHA, checkedAt: Date()))
            return .ok(map: tm.folderSHAs, root: tm.rootSHA)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
