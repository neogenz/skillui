import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @FocusState private var focus: Field?

    private enum Field { case cliPath, pat }
    private static let githubTokenURL = URL(string: "https://github.com/settings/personal-access-tokens/new?name=Skillui&description=Read-only+token+for+Skillui+GitHub+update+checks&expires_in=365&contents=read")!

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingsSection("General") {
                    settingsRow("Launch at login") {
                        Toggle("", isOn: $app.launchAtLogin)
                            .labelsHidden()
                    }
                    rowDivider
                    settingsRow("Check for updates") {
                        Picker("", selection: $app.refreshIntervalHours) {
                            Text("Every hour").tag(1.0)
                            Text("Every 3 hours").tag(3.0)
                            Text("Every 6 hours").tag(6.0)
                            Text("Every 12 hours").tag(12.0)
                            Text("Daily").tag(24.0)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                    rowDivider
                    fullWidthButton("Refresh now") { Task { await app.refresh(force: true) } }
                }

                settingsSection("Application Updates") {
                    fullWidthButton {
                        Task { await app.checkForAppUpdate(manual: true, force: true) }
                    } label: {
                        if app.isCheckingAppUpdate {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Check for Updates...")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(app.isCheckingAppUpdate)
                    rowDivider
                    caption("Checks GitHub Releases for a newer signed DMG. Skill updates above still use the skills CLI.")
                }

                settingsSection("skills CLI") {
                    settingsRow("npx / skills path") {
                        TextField("", text: $app.cliPathOverride, prompt: Text("auto-detect"))
                            .settingsTextField(focused: focus == .cliPath)
                            .focused($focus, equals: .cliPath)
                    }
                    rowDivider
                    caption("Leave empty to resolve `skills` or `npx` from your login shell.")
                }

                settingsSection("GitHub") {
                    if app.githubCredentialNeedsAttention {
                        caption("macOS blocked silent access to the stored token. Approve Always Allow once for the signed Skillui app, or paste the token again to replace the old dev entry.")
                        rowDivider
                    }
                    settingsRow("Personal access token") {
                        SecureField("", text: $app.githubPAT, prompt: Text("optional"))
                            .settingsTextField(focused: focus == .pat)
                            .focused($focus, equals: .pat)
                    }
                    rowDivider
                    settingsRow("Token setup") {
                        Button("Create prefilled token...") {
                            NSWorkspace.shared.open(Self.githubTokenURL)
                        }
                        .help("Opens GitHub fine-grained personal access token settings with Skillui's read-only defaults")
                    }
                    rowDivider
                    caption("The link pre-fills a fine-grained token named Skillui with a 1-year expiry and Contents read. In GitHub, choose public repositories read-only; leave every write, admin, workflow, package, and delete scope off.")
                    rowDivider
                    caption("Raises the update-check rate limit from 60 to 5000 requests/hour. Stored in your Keychain.")
                }

                settingsSection("Project folders") {
                    if app.projectRoots.isEmpty {
                        caption("No project folders. Add one to scan its project-scope skills.")
                    } else {
                        ForEach(Array(app.projectRoots.enumerated()), id: \.element) { index, root in
                            settingsRow((root as NSString).abbreviatingWithTildeInPath) {
                                Button(role: .destructive) {
                                    app.projectRoots.removeAll { $0 == root }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                            if index < app.projectRoots.count - 1 { rowDivider }
                        }
                    }
                    rowDivider
                    fullWidthButton("Add project folder...") { addProjectFolder(app) }
                }

                if !app.allAgents.isEmpty {
                    settingsSection("Visible agents") {
                        ForEach(Array(app.allAgents.enumerated()), id: \.element) { index, agent in
                            settingsRow(agent) {
                                Toggle("", isOn: Binding(
                                    get: { !app.hiddenAgents.contains(agent) },
                                    set: { visible in
                                        if visible { app.hiddenAgents.remove(agent) }
                                        else { app.hiddenAgents.insert(agent) }
                                    }
                                ))
                                .labelsHidden()
                            }
                            if index < app.allAgents.count - 1 { rowDivider }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .background(Theme.traySurface)
        .frame(width: 460, height: 540)
        .task {
            app.loadGitHubPATForEditing()
            // When opened from the rate-limit banner, focus the token field (not the first field).
            if app.requestPATFocus {
                app.requestPATFocus = false
                try? await Task.sleep(for: .milliseconds(120))   // let the default first-responder settle, then override
                focus = .pat
            }
        }
    }

    private func settingsSection(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) { rows() }
                .cardSurface()
        }
    }

    private func settingsRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 12)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fullWidthButton(_ title: String, action: @escaping () -> Void) -> some View {
        fullWidthButton(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
    }

    private func fullWidthButton(@ViewBuilder label: () -> some View, action: @escaping () -> Void) -> some View {
        fullWidthButton(action: action, label: label)
    }

    private func fullWidthButton(action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action, label: label)
            .controlSize(.regular)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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

private extension View {
    func settingsTextField(focused: Bool) -> some View {
        textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .frame(width: 150)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(focused ? Color.accentColor.opacity(0.75) : Theme.hairline.opacity(0.55),
                            lineWidth: focused ? 1.5 : 1)
            }
    }
}
