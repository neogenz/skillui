import SwiftUI

/// Settings window. (Group A: stub; real controls added in System integration step.)
struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Form {
            Text("Quiver settings")
                .font(.headline)
        }
        .padding(20)
        .frame(width: 460, height: 300)
    }
}
