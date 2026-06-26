import SwiftUI

/// Visual style for an agent, keyed by the *display name* that
/// `skills list --json` emits (e.g. "Claude Code", "Cursor", "Codex").
///
/// The skills CLI knows ~25+ agents and a single skill installed into the shared
/// `.agents/skills` dir is reported as belonging to many of them at once. We never
/// hardcode the agent list for discovery (the CLI owns that) — this registry only
/// maps known display names to an icon/tint, with a sensible fallback for the rest.
struct AgentStyle: Sendable {
    let symbol: String
    let tint: Color
    let short: String
}

enum AgentRegistry {
    static func style(for displayName: String) -> AgentStyle {
        switch displayName {
        case "Claude Code":    return .init(symbol: "sparkle",        tint: .orange, short: "Claude")
        case "Codex":          return .init(symbol: "chevron.left.forwardslash.chevron.right", tint: .teal, short: "Codex")
        case "Cursor":         return .init(symbol: "arrow.up.left.and.arrow.down.right", tint: .blue, short: "Cursor")
        case "Gemini CLI":     return .init(symbol: "diamond",        tint: .indigo, short: "Gemini")
        case "GitHub Copilot": return .init(symbol: "cat",            tint: .purple, short: "Copilot")
        case "Zed":            return .init(symbol: "bolt",           tint: .yellow, short: "Zed")
        case "Cline":          return .init(symbol: "terminal",       tint: .green, short: "Cline")
        case "OpenCode":       return .init(symbol: "curlybraces",    tint: .pink, short: "OpenCode")
        case "Warp":           return .init(symbol: "wave.3.forward", tint: .mint, short: "Warp")
        case "Windsurf":       return .init(symbol: "wind",           tint: .cyan, short: "Windsurf")
        case "Antigravity":    return .init(symbol: "arrow.up",       tint: .red, short: "AntiG")
        case "Amp":            return .init(symbol: "guitars",        tint: .brown, short: "Amp")
        case "Droid":          return .init(symbol: "ladybug",        tint: .green, short: "Droid")
        default:               return .init(symbol: "cpu",            tint: .gray, short: displayName)
        }
    }
}
