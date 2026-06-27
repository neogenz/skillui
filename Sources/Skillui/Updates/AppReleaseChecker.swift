import Foundation

/// GitHub Releases-based app updater. This intentionally does not self-patch the app:
/// keeping Skillui system-framework-only means the safe distribution path is a signed,
/// notarized DMG that the app downloads and opens for the user.
struct AppReleaseChecker: Sendable {
    let repository: String
    let token: String?
    var userAgent = "Skillui"

    enum ReleaseError: LocalizedError {
        case invalidRepository
        case http(Int)
        case noDMGAsset
        case noResponse

        var errorDescription: String? {
            switch self {
            case .invalidRepository: return "Release repository is not configured."
            case .http(404): return "No GitHub release was found for this app."
            case .http(403): return "GitHub rate limit reached. Add a token in Settings and try again."
            case .http(let code): return "GitHub HTTP \(code)"
            case .noDMGAsset: return "The latest release does not contain a DMG asset."
            case .noResponse: return "GitHub did not return a valid response."
            }
        }
    }

    func latestUpdate(currentVersion: String) async throws -> AppRelease? {
        let release = try await latestRelease()
        return Self.compareVersions(release.version, currentVersion) == .orderedDescending ? release : nil
    }

    private func latestRelease() async throws -> AppRelease {
        guard repository.split(separator: "/").count == 2 else { throw ReleaseError.invalidRepository }
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReleaseError.noResponse }
        guard http.statusCode == 200 else { throw ReleaseError.http(http.statusCode) }

        let gh = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = gh.assets.first(where: { Self.isDMGAssetName($0.name) }) else {
            throw ReleaseError.noDMGAsset
        }
        return AppRelease(tagName: gh.tagName,
                          version: Self.versionString(from: gh.tagName),
                          name: gh.name?.isEmpty == false ? gh.name! : gh.tagName,
                          body: gh.body ?? "",
                          htmlURL: URL(string: gh.htmlURL),
                          assetName: asset.name,
                          assetSize: asset.size,
                          assetDownloadURL: URL(string: asset.browserDownloadURL))
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let size: Int64
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case size
            case browserDownloadURL = "browser_download_url"
        }
    }

    static func versionString(from tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    static func isDMGAssetName(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".dmg")
    }

    /// Numeric semantic comparison with a pragmatic prerelease fallback.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = VersionParts(lhs)
        let r = VersionParts(rhs)
        for i in 0..<max(l.numbers.count, r.numbers.count) {
            let a = i < l.numbers.count ? l.numbers[i] : 0
            let b = i < r.numbers.count ? r.numbers[i] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        if l.prerelease == r.prerelease { return .orderedSame }
        if l.prerelease == nil { return .orderedDescending }
        if r.prerelease == nil { return .orderedAscending }
        return l.prerelease!.localizedStandardCompare(r.prerelease!)
    }

    private struct VersionParts {
        let numbers: [Int]
        let prerelease: String?

        init(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let split = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            numbers = split.first?
                .split(separator: ".")
                .map { Int($0.filter(\.isNumber)) ?? 0 } ?? []
            prerelease = split.count > 1 ? String(split[1]) : nil
        }
    }
}

struct AppRelease: Identifiable, Sendable, Equatable {
    let tagName: String
    let version: String
    let name: String
    let body: String
    let htmlURL: URL?
    let assetName: String
    let assetSize: Int64
    let assetDownloadURL: URL?

    var id: String { tagName }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: assetSize, countStyle: .file) }
}

enum AppUpdateResult: Sendable, Equatable {
    case checking
    case available(AppRelease)
    case upToDate(String)
    case failed(String)
}
