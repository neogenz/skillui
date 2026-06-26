import Foundation

/// Computes a skill's `UpdateStatus` by comparing the upstream folder tree SHA against
/// the installed `skillFolderHash`. Resolves the default branch when `ref` is absent,
/// and honors the cache (TTL + ETag) to stay under GitHub rate limits.
struct UpdateChecker: Sendable {
    let token: String?
    var cache: UpdateCacheStore? = nil

    private var gh: GitHubClient { GitHubClient(token: token) }

    /// Pure decision: compare installed folder tree SHA against the latest upstream one.
    static func decide(installed: String, latest: String?) -> UpdateStatus {
        guard let latest else { return .failed("skill folder not found upstream") }
        return latest == installed ? .upToDate : .updateAvailable
    }

    func status(for skill: Skill, ttl: TimeInterval = 6 * 3600, force: Bool = false) async -> UpdateStatus {
        guard skill.canCheckUpdate,
              let repo = skill.source,
              let folder = skill.repoFolder,
              let installed = skill.lock?.skillFolderHash,
              let key = skill.updateKey else {
            return .unsupported
        }

        // Fresh-enough cache hit → no network.
        if !force, let store = cache, let e = await store.get(key),
           Date().timeIntervalSince(e.checkedAt) < ttl, let latest = e.latestSha {
            return latest == installed ? .upToDate : .updateAvailable
        }

        do {
            let ref: String
            if let r = skill.lock?.ref, !r.isEmpty { ref = r }
            else { ref = try await gh.defaultBranch(repo: repo) }

            let priorEtag = await cache?.get(key)?.etag
            let res = try await gh.folderTreeSHA(repo: repo, ref: ref, folder: folder, etag: priorEtag)

            if res.notModified, let latest = await cache?.get(key)?.latestSha {
                await cache?.set(key, .init(latestSha: latest, etag: res.etag, checkedAt: Date()))
                return Self.decide(installed: installed, latest: latest)
            }
            await cache?.set(key, .init(latestSha: res.sha, etag: res.etag, checkedAt: Date()))
            return Self.decide(installed: installed, latest: res.sha)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
