import Foundation

/// Minimal GitHub REST client for update detection. No third-party deps.
struct GitHubClient: Sendable {
    let token: String?

    struct TreeEntry: Decodable, Sendable {
        let path: String
        let type: String
        let sha: String
    }
    struct TreeResponse: Decodable, Sendable {
        let tree: [TreeEntry]?
        let truncated: Bool?
    }
    private struct RepoMeta: Decodable, Sendable { let default_branch: String? }

    enum GHError: Error, LocalizedError {
        case http(Int)
        case noResponse
        var errorDescription: String? {
            switch self {
            case .http(403): return "GitHub rate limit (add a token in Settings)"
            case .http(404): return "repo or branch not found"
            case .http(let c): return "GitHub HTTP \(c)"
            case .noResponse: return "no response"
            }
        }
    }

    private func makeRequest(_ url: URL, etag: String? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("quiver", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return r
    }

    /// Repo default branch — needed because lockfiles usually omit `ref`.
    func defaultBranch(repo: String) async throws -> String {
        let url = URL(string: "https://api.github.com/repos/\(repo)")!
        let (data, resp) = try await URLSession.shared.data(for: makeRequest(url))
        guard let http = resp as? HTTPURLResponse else { throw GHError.noResponse }
        guard http.statusCode == 200 else { throw GHError.http(http.statusCode) }
        return (try? JSONDecoder().decode(RepoMeta.self, from: data))?.default_branch ?? "main"
    }

    struct TreeSHAResult: Sendable {
        var sha: String?      // folder tree SHA, nil if folder not present upstream
        var etag: String?
        var notModified: Bool // 304 — caller reuses cached value
    }

    /// Folder tree SHA at `ref`. Uses ETag conditional requests; handles `truncated`.
    func folderTreeSHA(repo: String, ref: String, folder: String, etag: String?) async throws -> TreeSHAResult {
        let url = URL(string: "https://api.github.com/repos/\(repo)/git/trees/\(ref)?recursive=1")!
        let (data, resp) = try await URLSession.shared.data(for: makeRequest(url, etag: etag))
        guard let http = resp as? HTTPURLResponse else { throw GHError.noResponse }
        if http.statusCode == 304 { return TreeSHAResult(sha: nil, etag: etag, notModified: true) }
        guard http.statusCode == 200 else { throw GHError.http(http.statusCode) }
        let newEtag = http.value(forHTTPHeaderField: "Etag")
        let tree = try JSONDecoder().decode(TreeResponse.self, from: data)

        if tree.truncated == true {
            let sha = try await walk(repo: repo, ref: ref, folder: folder)
            return TreeSHAResult(sha: sha, etag: newEtag, notModified: false)
        }
        let entry = tree.tree?.first { $0.path == folder && $0.type == "tree" }
        return TreeSHAResult(sha: entry?.sha, etag: newEtag, notModified: false)
    }

    /// Truncated-tree fallback: descend the path one level at a time (non-recursive trees).
    private func walk(repo: String, ref: String, folder: String) async throws -> String? {
        var current = ref
        let segments = folder.split(separator: "/").map(String.init)
        for (i, seg) in segments.enumerated() {
            let url = URL(string: "https://api.github.com/repos/\(repo)/git/trees/\(current)")!
            let (data, resp) = try await URLSession.shared.data(for: makeRequest(url))
            guard let http = resp as? HTTPURLResponse else { throw GHError.noResponse }
            guard http.statusCode == 200 else { throw GHError.http(http.statusCode) }
            let tree = try JSONDecoder().decode(TreeResponse.self, from: data)
            guard let entry = tree.tree?.first(where: { $0.path == seg && $0.type == "tree" }) else { return nil }
            if i == segments.count - 1 { return entry.sha }
            current = entry.sha
        }
        return nil
    }
}
