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
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10)).foregroundStyle(.green.opacity(0.85)).help("Up to date")
        case .failed(let msg):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9)).foregroundStyle(.yellow).help(msg)
        case .unknown, .unsupported:
            EmptyView()
        }
    }
}

/// Compact agent presence: a few tinted glyphs + overflow count. THE cross-agent signal.
struct AgentChips: View {
    let agents: [String]
    private let maxShown = 5
    var body: some View {
        HStack(spacing: 3) {
            ForEach(agents.prefix(maxShown), id: \.self) { a in
                let st = AgentRegistry.style(for: a)
                Image(systemName: st.symbol)
                    .font(.system(size: 8.5))
                    .foregroundStyle(st.tint)
                    .frame(width: 15, height: 15)
                    .background(st.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .help(a)
            }
            if agents.count > maxShown {
                Text("+\(agents.count - maxShown)")
                    .font(.system(size: 8.5, weight: .medium)).foregroundStyle(.secondary)
                    .help(agents.dropFirst(maxShown).joined(separator: ", "))
            }
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
