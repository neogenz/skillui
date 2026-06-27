import Foundation

enum UpdateActivityStatus: String, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case skipped

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        }
    }

    var isFinished: Bool {
        switch self {
        case .queued, .running: return false
        case .succeeded, .failed, .skipped: return true
        }
    }
}

struct UpdateActivityItem: Identifiable, Sendable {
    let id: UUID
    var title: String
    var subtitle: String
    var command: String?
    var status: UpdateActivityStatus
    var startedAt: Date?
    var finishedAt: Date?
    var log: String

    init(id: UUID = UUID(),
         title: String,
         subtitle: String = "",
         command: String? = nil,
         status: UpdateActivityStatus = .queued,
         startedAt: Date? = nil,
         finishedAt: Date? = nil,
         log: String = "") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.command = command
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.log = log
    }

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

struct UpdateActivitySession: Identifiable, Sendable {
    let id: UUID
    var title: String
    var subtitle: String
    var startedAt: Date
    var finishedAt: Date?
    var items: [UpdateActivityItem]

    init(id: UUID = UUID(),
         title: String,
         subtitle: String,
         startedAt: Date = Date(),
         finishedAt: Date? = nil,
         items: [UpdateActivityItem]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.items = items
    }

    var totalCount: Int { items.count }
    var completedCount: Int { items.filter(\.status.isFinished).count }
    var failedCount: Int { items.filter { $0.status == .failed }.count }
    var runningCount: Int { items.filter { $0.status == .running }.count }
    var isRunning: Bool { finishedAt == nil && items.contains { !$0.status.isFinished } }

    var combinedLog: String {
        items.map { item in
            let command = item.command.map { "\n$ \($0)" } ?? ""
            let body = item.log.isEmpty ? "(no output)" : item.log.trimmingCharacters(in: .whitespacesAndNewlines)
            return "## \(item.title) [\(item.status.label)]\(command)\n\(body)"
        }
        .joined(separator: "\n\n")
    }

    static var preview: UpdateActivitySession {
        let now = Date()
        return UpdateActivitySession(
            title: "Updating 26 skills",
            subtitle: "skills update is running across global and project scopes.",
            startedAt: now.addingTimeInterval(-32),
            items: [
                UpdateActivityItem(
                    title: "Update angular-developer",
                    subtitle: "project · briefConducteur",
                    command: "cd ~/workspace/briefConducteur\nnpx skills update angular-developer -p -y",
                    status: .succeeded,
                    startedAt: now.addingTimeInterval(-32),
                    finishedAt: now.addingTimeInterval(-22),
                    log: "Source: https://github.com/angular/angular\nRepository cloned\nFound 1 skill\nSelected 1 skill: angular-developer\nDone."),
                UpdateActivityItem(
                    title: "Update impeccable",
                    subtitle: "project · pulpe-workspace › pul-17-lisser-depense",
                    command: "cd ~/workspace/pulpe-workspace/.codex/worktrees/pul-17-lisser-depense\nnpx skills update impeccable -p -y",
                    status: .running,
                    startedAt: now.addingTimeInterval(-21),
                    log: "Source: https://github.com/pbakaus/impeccable.git\nRepository cloned\nFound 1 skill\nSelected 1 skill: impeccable\nInstalling into project scope..."),
                UpdateActivityItem(
                    title: "Recheck update status",
                    subtitle: "GitHub tree SHA comparison",
                    status: .queued)
            ])
    }
}
