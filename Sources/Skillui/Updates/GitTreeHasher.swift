import Foundation
import CryptoKit

/// Computes the **git tree SHA-1** of a local folder, byte-for-byte compatible with what
/// GitHub returns for that folder in a tree listing. This lets project-local skills (whose
/// lockfile stores a sha256 content-hash, not a git tree SHA) be compared against upstream:
/// hash the installed folder, compare to the upstream folder tree SHA.
///
/// Git object rules implemented here:
///   blob = sha1("blob <len>\0" + content)
///   tree = sha1("tree <len>\0" + Σ "<mode> <name>\0" + 20-byte-sha), entries sorted by
///          name with a trailing "/" appended for subtrees (git's base_name_compare).
///   modes: 100644 file, 100755 exec, 120000 symlink, 40000 dir.
enum GitTreeHasher {
    static func treeSHA(_ dir: URL) -> String? {
        treeRaw(dir).map { $0.map { String(format: "%02x", $0) }.joined() }
    }

    /// Cheap metadata signature (relative path + size + mtime) to detect whether a folder
    /// changed since we last hashed it — avoids re-reading every file when nothing moved.
    static func signature(_ dir: URL) -> String {
        var parts: [String] = []
        collectSignature(dir, base: dir, into: &parts)
        parts.sort()
        let joined = parts.joined(separator: "\n")
        let digest = Insecure.SHA1.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Tree hashing

    private struct Entry { let mode: String; let name: String; let sha: [UInt8]; let isTree: Bool }

    private static func treeRaw(_ dir: URL) -> [UInt8]? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isExecutableKey],
            options: []) else { return nil }

        var entries: [Entry] = []
        for item in items {
            let name = item.lastPathComponent
            if name == ".git" || name == ".DS_Store" { continue }
            let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isExecutableKey])
            let isSymlink = vals?.isSymbolicLink ?? false
            if isSymlink {
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: item.path) else { continue }
                entries.append(Entry(mode: "120000", name: name, sha: blobRaw(Data(dest.utf8)), isTree: false))
            } else if vals?.isDirectory == true {
                guard let sha = treeRaw(item) else { continue }
                entries.append(Entry(mode: "40000", name: name, sha: sha, isTree: true))
            } else {
                guard let data = try? Data(contentsOf: item) else { continue }
                let mode = (vals?.isExecutable == true) ? "100755" : "100644"
                entries.append(Entry(mode: mode, name: name, sha: blobRaw(data), isTree: false))
            }
        }

        entries.sort { lexLess(sortKey($0), sortKey($1)) }

        var content = [UInt8]()
        for e in entries {
            content.append(contentsOf: Array("\(e.mode) \(e.name)".utf8))
            content.append(0)
            content.append(contentsOf: e.sha)
        }
        return objectRaw(type: "tree", content: content)
    }

    private static func sortKey(_ e: Entry) -> [UInt8] {
        Array((e.name + (e.isTree ? "/" : "")).utf8)
    }

    private static func blobRaw(_ data: Data) -> [UInt8] {
        objectRaw(type: "blob", content: Array(data))
    }

    private static func objectRaw(type: String, content: [UInt8]) -> [UInt8] {
        var bytes = Array("\(type) \(content.count)".utf8)
        bytes.append(0)
        bytes.append(contentsOf: content)
        return Array(Insecure.SHA1.hash(data: Data(bytes)))
    }

    private static func lexLess(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let n = min(a.count, b.count)
        for i in 0..<n where a[i] != b[i] { return a[i] < b[i] }
        return a.count < b.count
    }

    // MARK: - Signature

    private static func collectSignature(_ dir: URL, base: URL, into parts: inout [String]) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: []) else { return }
        for item in items {
            let name = item.lastPathComponent
            if name == ".git" || name == ".DS_Store" { continue }
            let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if vals?.isDirectory == true {
                collectSignature(item, base: base, into: &parts)
            } else {
                let rel = item.path.replacingOccurrences(of: base.path + "/", with: "")
                let size = vals?.fileSize ?? 0
                let mtime = vals?.contentModificationDate?.timeIntervalSince1970 ?? 0
                parts.append("\(rel)\u{0}\(size)\u{0}\(mtime)")
            }
        }
    }
}
