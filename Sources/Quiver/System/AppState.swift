import SwiftUI
import Observation

/// Central app coordinator. Holds the in-memory skill list and update statuses,
/// drives scans and update checks. (Group A: skeleton; real wiring added next.)
@MainActor
@Observable
final class AppState {
    /// All discovered skills (re-derived on each scan; never persisted).
    var skills: [Skill] = []

    /// skill.id → update status.
    var statuses: [String: UpdateStatus] = [:]

    var isScanning = false
    var isCheckingUpdates = false
    var lastError: String?

    /// Count of skills with an available update.
    var updateCount: Int {
        skills.reduce(into: 0) { acc, s in
            if statuses[s.id] == .updateAvailable { acc += 1 }
        }
    }

    func scan() async {
        // Implemented in Discovery wiring (Group B).
    }

    func checkUpdates(force: Bool = false) async {
        // Implemented in Updates wiring (Group C).
    }
}
