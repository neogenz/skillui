import SwiftUI
import AppKit

/// A single skill row: name + version + status, source + agent chips, and trailing
/// actions (Update when available, GitHub link). Row click opens the skills.sh page.
struct SkillRowView: View {
    let skill: Skill
    let status: UpdateStatus
    @Environment(AppState.self) private var app
    @State private var hovering = false

    private var isUpdating: Bool { app.updatingSkillIDs.contains(skill.id) }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let v = skill.shortVersion { VersionChip(sha: v) }
                    StatusBadge(status: status)
                }
                HStack(spacing: 6) {
                    if let src = skill.source {
                        Text(src).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("untracked").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    AgentChips(agents: skill.agents)
                }
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.vertical, Theme.rowVPad)
        .padding(.horizontal, Theme.rowHPad)
        .background(hovering ? Theme.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { open(skill.skillsShURL) }
        .help(skill.skillsShURL.map { "Open \($0.absoluteString)" } ?? skill.name)
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 2) {
            if isUpdating {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 28)
            } else if status == .updateAvailable {
                Button("Update") { Task { await app.updateSkill(skill) } }
                    .buttonStyle(.borderedProminent).tint(Theme.amber).controlSize(.small)
                    .help("Run `skills update \(skill.name)`")
            }
            if skill.githubURL != nil {
                IconButton(systemName: "arrow.up.forward.app", help: "Open GitHub repo") {
                    open(skill.githubURL)
                }
                .opacity(hovering ? 1 : 0.5)
            }
        }
    }

    private func open(_ url: URL?) { if let url { NSWorkspace.shared.open(url) } }
}
