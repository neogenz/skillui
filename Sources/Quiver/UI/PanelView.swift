import SwiftUI

/// The menu-bar panel. (Group A: header + empty/placeholder body; rich rows added later.)
struct PanelView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if app.skills.isEmpty {
                    placeholder
                } else {
                    Text("\(app.skills.count) skills")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        }
        .frame(width: Theme.panelWidth, height: 420)
        .task { await app.scan() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(Theme.amber)
            Text("Quiver").font(.headline)
            Spacer()
            Button { Task { await app.scan() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
            Text("No skills found").font(.callout)
            Text("Install one with `npx skills add …`")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }
}
