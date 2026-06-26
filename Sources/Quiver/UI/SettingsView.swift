import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $app.launchAtLogin)
                Picker("Check for updates", selection: $app.refreshIntervalHours) {
                    Text("Every hour").tag(1.0)
                    Text("Every 3 hours").tag(3.0)
                    Text("Every 6 hours").tag(6.0)
                    Text("Every 12 hours").tag(12.0)
                    Text("Daily").tag(24.0)
                }
                Button("Refresh now") { Task { await app.refresh(force: true) } }
            }

            Section("skills CLI") {
                TextField("npx / skills path", text: $app.cliPathOverride, prompt: Text("auto-detect"))
                    .textFieldStyle(.roundedBorder)
                Text("Leave empty to resolve `skills` or `npx` from your login shell.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("GitHub") {
                SecureField("Personal access token", text: $app.githubPAT, prompt: Text("optional"))
                    .textFieldStyle(.roundedBorder)
                Text("Raises the update-check rate limit from 60 to 5000 requests/hour. Stored in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Project folders") {
                if app.projectRoots.isEmpty {
                    Text("No project folders. Add one to scan its project-scope skills.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(app.projectRoots, id: \.self) { root in
                        HStack {
                            Text((root as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 11)).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Button(role: .destructive) {
                                app.projectRoots.removeAll { $0 == root }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add project folder…") { addProjectFolder(app) }
            }

            if !app.allAgents.isEmpty {
                Section("Visible agents") {
                    ForEach(app.allAgents, id: \.self) { agent in
                        Toggle(agent, isOn: Binding(
                            get: { !app.hiddenAgents.contains(agent) },
                            set: { visible in
                                if visible { app.hiddenAgents.remove(agent) }
                                else { app.hiddenAgents.insert(agent) }
                            }
                        ))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 540)
    }

    private func addProjectFolder(_ app: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url, !app.projectRoots.contains(url.path) {
            app.projectRoots.append(url.path)
        }
    }
}
