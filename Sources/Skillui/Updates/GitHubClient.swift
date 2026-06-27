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
        let sha: String?           // the tree's own SHA (= the repo root folder SHA)
        let tree: [TreeEntry]?
        let truncated: Bool?
    }
    private struct RepoMeta: Decodable, Sendable { let default_branch: String? }
    private struct ContentResponse: Decodable, Sendable {
        let content: String?
        let encoding: String?
    }

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
        r.setValue("skillui", forHTTPHeaderField: "User-Agent")
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

    struct TreeMap: Sendable {
        var folderSHAs: [String: String]  // repo-relative folder path → tree SHA
        var rootSHA: String?              // "" folder (repo root)
        var etag: String?
        var notModified: Bool             // 304 — caller reuses the cached map
        var truncated: Bool               // partial map (huge repo); missing folders → no result
    }

    /// One recursive tree fetch per (repo, ref) → SHAs for ALL folders at once. This is what
    /// lets every skill from the same repo share a single request (and a single ETag), instead
    /// of one full-tree download per skill folder. Uses ETag conditional requests.
    func folderSHAMap(repo: String, ref: String, etag: String?) async throws -> TreeMap {
        let url = URL(string: "https://api.github.com/repos/\(repo)/git/trees/\(ref)?recursive=1")!
        let (data, resp) = try await URLSession.shared.data(for: makeRequest(url, etag: etag))
        guard let http = resp as? HTTPURLResponse else { throw GHError.noResponse }
        if http.statusCode == 304 {
            return TreeMap(folderSHAs: [:], rootSHA: nil, etag: etag, notModified: true, truncated: false)
        }
        guard http.statusCode == 200 else { throw GHError.http(http.statusCode) }
        let newEtag = http.value(forHTTPHeaderField: "Etag")
        let tree = try JSONDecoder().decode(TreeResponse.self, from: data)
        var map: [String: String] = [:]
        for e in tree.tree ?? [] where e.type == "tree" { map[e.path] = e.sha }
        return TreeMap(folderSHAs: map, rootSHA: tree.sha, etag: newEtag,
                       notModified: false, truncated: tree.truncated == true)
    }

    func fileContents(repo: String, path: String, ref: String) async throws -> Data {
        let encodedPath = path.split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        var comps = URLComponents(string: "https://api.github.com/repos/\(repo)/contents/\(encodedPath)")!
        comps.queryItems = [URLQueryItem(name: "ref", value: ref)]
        let (data, resp) = try await URLSession.shared.data(for: makeRequest(comps.url!))
        guard let http = resp as? HTTPURLResponse else { throw GHError.noResponse }
        guard http.statusCode == 200 else { throw GHError.http(http.statusCode) }
        let decoded = try JSONDecoder().decode(ContentResponse.self, from: data)
        guard decoded.encoding == "base64",
              let content = decoded.content else { throw GHError.noResponse }
        let normalized = content.replacingOccurrences(of: "\n", with: "")
        guard let bytes = Data(base64Encoded: normalized) else { throw GHError.noResponse }
        return bytes
    }
}
