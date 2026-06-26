import SwiftUI

/// How a discovered skill physically lives on disk — the key cross-project distinction:
/// is a project's skill its own copy, or just a symlink into the global install?
enum LinkType: String, Sendable, Equatable, Codable {
    case global          // the canonical global install itself (e.g. ~/.agents/skills/<name>)
    case linkedGlobal    // a symlink from a project INTO the global install
    case projectLocal    // a real directory that lives in the project (owned by it)
    case linkedExternal  // a symlink pointing somewhere outside the global root

    var label: String {
        switch self {
        case .global: return "Global"
        case .linkedGlobal: return "Linked"
        case .projectLocal: return "Local"
        case .linkedExternal: return "External"
        }
    }

    var help: String {
        switch self {
        case .global: return "Global install"
        case .linkedGlobal: return "Symlink into the global install — shared with the global skill"
        case .projectLocal: return "Real directory owned by this project"
        case .linkedExternal: return "Symlink to a location outside the global root"
        }
    }

    var symbol: String {
        switch self {
        case .global: return "globe"
        case .linkedGlobal: return "link"
        case .projectLocal: return "folder.fill"
        case .linkedExternal: return "arrow.up.forward"
        }
    }

    var tint: Color {
        switch self {
        case .global: return .blue
        case .linkedGlobal: return .teal
        case .projectLocal: return .purple
        case .linkedExternal: return .orange
        }
    }
}
