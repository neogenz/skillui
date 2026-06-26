import Foundation

/// Persisted update-check cache. Keyed by a skill's `updateKey` (source@ref::folder).
/// The ONLY thing Quiver persists besides settings — lets badges survive relaunch and
/// avoids re-hitting GitHub on every panel open (60 req/hr unauthenticated).
struct UpdateCache: Codable, Sendable {
    var version = 1
    var entries: [String: Entry] = [:]

    struct Entry: Codable, Sendable {
        var latestSha: String?
        var etag: String?
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
        if let data = try? Data(contentsOf: url), let c = try? dec.decode(UpdateCache.self, from: data) {
            self.cache = c
        } else {
            self.cache = UpdateCache()
        }
    }

    func get(_ key: String) -> UpdateCache.Entry? { cache.entries[key] }

    func set(_ key: String, _ entry: UpdateCache.Entry) {
        cache.entries[key] = entry
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(cache) { try? data.write(to: url, options: .atomic) }
    }
}
