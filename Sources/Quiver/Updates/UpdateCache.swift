import Foundation

/// Persisted update-check cache. Keyed per (repo, ref) — one entry covers EVERY skill folder
/// in that repo (a single recursive tree fetch), plus a default-branch cache so we don't
/// re-resolve it each run. The only thing Quiver persists besides settings; lets badges
/// survive relaunch and keeps us well under GitHub's 60 req/hr unauthenticated ceiling.
struct UpdateCache: Codable, Sendable {
    static let currentVersion = 2
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

/// Thread-safe owner of the cache file (`~/Library/Application Support/Quiver/update-cache.json`).
actor UpdateCacheStore {
    private var cache: UpdateCache
    private let url: URL

    init() {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))?
            .appendingPathComponent("Quiver", isDirectory: true)
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
    func setTree(_ key: String, _ entry: UpdateCache.TreeEntry) { cache.trees[key] = entry; save() }

    func branch(_ repo: String) -> String? { cache.branches[repo] }
    func setBranch(_ repo: String, _ branch: String) { cache.branches[repo] = branch; save() }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(cache) { try? data.write(to: url, options: .atomic) }
    }
}
