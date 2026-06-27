import Foundation

/// Install scope as reported by `skills list --json`.
enum Scope: String, Codable, Sendable, CaseIterable, Hashable {
    case global
    case project

    var label: String {
        switch self {
        case .global: return "Global"
        case .project: return "Project"
        }
    }

    /// Flag passed to `skills list` / `skills update`.
    var cliFlag: String {
        switch self {
        case .global: return "-g"
        case .project: return "-p"
        }
    }
}
