import Foundation
import CryptoKit

/// Hashes used by the `skills` CLI project lockfile.
enum SkillsContentHasher {
    /// Matches skills@1.5.13's `computeSingleFileSkillHash(contents)`.
    static func singleFileHash(contents: Data) -> String {
        var data = Data("SKILL.md".utf8)
        data.append(contents)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
