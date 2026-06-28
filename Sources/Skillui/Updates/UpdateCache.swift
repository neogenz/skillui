import Foundation

/// Persisted update-check cache. Keyed per (repo, ref) — one entry covers EVERY global skill folder
/// in that repo (a single recursive tree fetch), plus a default-branch cache so we don't
/// re-resolve it each run. The only thing Skillui persists besides settings; lets badges
/// survive relaunch and keeps us well under GitHub's 60 req/hr unauthenticated ceiling.
struct UpdateCache: Codable, Sendable {
    static let currentVersion = 3
    var version = currentVersion
    var trees: [String: TreeEntry] = [:]      // "repo@ref" → folder SHAs
    var branches: [String: String] = [:]      // repo → default branch

    struct TreeEntry: Codable, Sendable {
        var etag: String?
        var folderSHAs: [String: String]
        var rootSHA: String?
        var checkedAt: Date
    }

}

/// Thread-safe owner of the cache file (`~/Library/Application Support/Skillui/update-cache.json`).
actor UpdateCacheStore {
    private var cache: UpdateCache
    private let url: URL
    /// Pending mutations not yet written. The cache is persisted once per batch via `flush()` instead
    /// of on every `setTree`/`setBranch` — a many-repo sweep used to re-serialize the whole growing
    /// cache N times (~O(N²) encode work) because every set called `save()`.
    private var dirty = false
    /// In-flight tree fetches keyed by cacheKey, so concurrent callers (e.g. the panel's global check
    /// and the dashboard's project check hitting the SAME repo with no stored ref) share ONE network
    /// request instead of each spending a slot of GitHub's 60 req/hr ceiling.
    private var inFlight: [String: Task<TreeFetch, Never>] = [:]

    /// Outcome of a coalesced tree fetch. Sendable so it can cross the actor boundary.
    enum TreeFetch: Sendable {
        case entry(UpdateCache.TreeEntry)
        case failure(String)
    }

    init() {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))?
            .appendingPathComponent("Skillui", isDirectory: true)
        if let dir { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        self.url = (dir ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("update-cache.json")

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let c = try? dec.decode(UpdateCache.self, from: data),
           c.version == UpdateCache.currentVersion {
            self.cache = c
        } else {
            self.cache = UpdateCache()   // fresh (missing or older schema)
        }
    }

    func tree(_ key: String) -> UpdateCache.TreeEntry? { cache.trees[key] }
    func setTree(_ key: String, _ entry: UpdateCache.TreeEntry) { cache.trees[key] = entry; dirty = true }

    func branch(_ repo: String) -> String? { cache.branches[repo] }
    func setBranch(_ repo: String, _ branch: String) { cache.branches[repo] = branch; dirty = true }

    /// Single-flight tree resolution. A fresh (within `ttl`) cache hit returns immediately without a
    /// network call; otherwise concurrent callers for the same `key` join ONE shared `fetch`. Only a
    /// successful `.entry` is cached + marked dirty (a `.failure` is never cached). `fetch` receives the
    /// prior cached entry so it can pass its ETag for a conditional request.
    func resolveTree(key: String, ttl: TimeInterval, force: Bool,
                     fetch: @Sendable @escaping (_ prior: UpdateCache.TreeEntry?) async -> TreeFetch) async -> TreeFetch {
        if !force, let e = cache.trees[key], Date().timeIntervalSince(e.checkedAt) < ttl {
            return .entry(e)
        }
        if let existing = inFlight[key] { return await existing.value }   // join the in-flight fetch
        let prior = cache.trees[key]
        let task = Task { await fetch(prior) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if case .entry(let e) = result { cache.trees[key] = e; dirty = true }
        return result
    }

    /// Persist pending mutations once. Called at the end of a batch (UpdateChecker.evaluate) so a
    /// sweep performs a single encode + atomic write instead of one per entry.
    func flush() {
        guard dirty else { return }
        dirty = false
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(cache) { try? data.write(to: url, options: .atomic) }
    }
}
