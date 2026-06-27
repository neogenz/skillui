import SwiftUI

/// Short monospaced SHA shown as the skill's "version".
struct VersionChip: View {
    let sha: String
    var body: some View {
        Text(sha)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Theme.subtle.opacity(0.5), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Update state badge.
struct StatusBadge: View {
    let status: UpdateStatus
    var body: some View {
        switch status {
        case .updateAvailable:
            // Compact glance signal; the trailing "Update" button carries the action.
            Circle().fill(Theme.amber).frame(width: 6, height: 6).help("Update available")
        case .checking:
            ProgressView().controlSize(.mini).scaleEffect(0.65).frame(width: 12, height: 12)
        case .upToDate:
            // The quiet default: a tertiary check, not a saturated green badge. With most rows
            // up to date, green-everywhere is noise — muting it makes an amber update unmissable.
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary).help("Up to date")
        case .failed(let msg):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9)).foregroundStyle(Theme.statusWarn).help(msg)
        case .unknown, .unsupported:
            EmptyView()
        }
    }
}

/// Compact agent presence — THE cross-agent signal. A hand-picked subset shows as tinted
/// glyphs (which agents matters); the shared-dir "installed everywhere" case collapses to an
/// honest count, because a row of identical icons + "+29" said the same nothing on every row.
struct AgentChips: View {
    let agents: [String]
    /// Glass capsule in the low-density panel; flat fill in the dense dashboard table.
    var glass = true
    private let maxShown = 5

    var body: some View {
        if agents.count > maxShown {
            countPill
        } else {
            HStack(spacing: 3) {
                ForEach(agents, id: \.self) { a in
                    let st = AgentRegistry.style(for: a)
                    Image(systemName: st.symbol)
                        .font(.system(size: 8.5))
                        .foregroundStyle(st.tint)
                        .frame(width: 15, height: 15)
                        .background(st.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .help(a)
                }
            }
        }
    }

    @ViewBuilder private var countPill: some View {
        let label = Label("\(agents.count) agents", systemImage: "square.grid.2x2.fill")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .help(agents.joined(separator: ", "))
        if glass {
            label.chipSurface()
        } else {
            label.background(.fill.quaternary, in: Capsule())
        }
    }
}

/// Borderless icon button used for row link actions.
struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Centered empty/error state.
struct StateMessage: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 54)
    }
}
