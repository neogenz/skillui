import SwiftUI
import AppKit

struct UpdateActivityView: View {
    @Environment(AppState.self) private var app
    @State private var selection: UUID?
    var staticIndicators = false

    var body: some View {
        Group {
            if let activity = app.updateActivity {
                activityContent(activity)
            } else {
                ContentUnavailableView("No update activity", systemImage: "doc.text",
                                       description: Text("Run a skill update or install missing project skills to see its log here."))
                    .frame(minWidth: 640, minHeight: 420)
            }
        }
        .background(Theme.traySurface)
        .onAppear { selectDefaultItem() }
        .onChange(of: app.updateActivity?.id) { selectDefaultItem() }
        .onChange(of: app.updateActivity?.items.count) { selectDefaultItem(onlyIfNil: true) }
    }

    private func activityContent(_ activity: UpdateActivitySession) -> some View {
        VStack(spacing: 0) {
            header(activity)
            Divider()
            HStack(spacing: 0) {
                timeline(activity)
                    .frame(width: 260)
                Divider()
                detail(activity)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    private func header(_ activity: UpdateActivitySession) -> some View {
        HStack(spacing: 14) {
            statusIcon(activity)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(activity.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(summary(activity))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(summaryColor(activity))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(summaryColor(activity).opacity(0.12), in: Capsule())
                }
                Text(activity.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                ProgressView(value: Double(activity.completedCount),
                             total: Double(max(activity.totalCount, 1)))
                    .frame(width: 150)
                    .tint(activity.failedCount > 0 ? .red : Theme.amber)
                Text("\(activity.completedCount) of \(activity.totalCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button {
                copy(activity.combinedLog)
            } label: {
                Label("Copy all", systemImage: "doc.on.doc")
            }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func timeline(_ activity: UpdateActivitySession) -> some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(activity.items) { item in
                    Button {
                        selection = item.id
                    } label: {
                        activityRow(item, selected: item.id == selectedItemID(activity))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    .accessibilityValue("\(item.status.label), \(item.subtitle)")
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func activityRow(_ item: UpdateActivityItem, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            itemStatusIcon(item)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(item.status.label)
                    if let duration = item.duration {
                        Text("·")
                        Text(durationLabel(duration))
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .contentShape(Rectangle())
    }

    private func detail(_ activity: UpdateActivitySession) -> some View {
        let item = selectedItem(activity)
        return VStack(alignment: .leading, spacing: 0) {
            if let item {
                detailHeader(item)
                Divider()
                logPane(item)
            } else {
                ContentUnavailableView("No step selected", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailHeader(_ item: UpdateActivityItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                itemStatusIcon(item)
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    copy(logText(for: item))
                } label: {
                    Label("Copy log", systemImage: "doc.on.doc")
                }
                    .controlSize(.small)
            }
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let command = item.command {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
        }
        .padding(14)
    }

    private func logPane(_ item: UpdateActivityItem) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(logText(for: item))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
                Color.clear.frame(height: 1).id("bottom")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: item.log.count) {
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func selectedItem(_ activity: UpdateActivitySession) -> UpdateActivityItem? {
        if let selection,
           let item = activity.items.first(where: { $0.id == selection }) {
            return item
        }
        return activity.items.first { $0.status == .running }
            ?? activity.items.first { $0.status == .warning }
            ?? activity.items.first { $0.status == .failed }
            ?? activity.items.last
    }

    private func selectedItemID(_ activity: UpdateActivitySession) -> UUID? {
        selectedItem(activity)?.id
    }

    private func selectDefaultItem(onlyIfNil: Bool = false) {
        if onlyIfNil, selection != nil { return }
        guard let activity = app.updateActivity else { return }
        selection = selectedItemID(activity)
    }

    private func statusIcon(_ activity: UpdateActivitySession) -> some View {
        ZStack {
            Circle().fill(summaryColor(activity).opacity(0.14))
            if activity.runningCount > 0 {
                if staticIndicators {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(summaryColor(activity))
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                Image(systemName: activity.failedCount > 0 ? "xmark" : activity.warningCount > 0 ? "exclamationmark" : "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(summaryColor(activity))
            }
        }
        .frame(width: 32, height: 32)
    }

    @ViewBuilder private func itemStatusIcon(_ item: UpdateActivityItem) -> some View {
        switch item.status {
        case .running:
            if staticIndicators {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(Theme.amber)
            } else {
                ProgressView().controlSize(.small).scaleEffect(0.65)
            }
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.amber)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "forward.circle.fill").foregroundStyle(.secondary)
        case .queued:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        }
    }

    private func summary(_ activity: UpdateActivitySession) -> String {
        if activity.runningCount > 0 { return "Running" }
        if activity.failedCount > 0 { return "\(activity.failedCount) failed" }
        if activity.warningCount > 0 { return "\(activity.warningCount) needs attention" }
        if activity.completedCount == activity.totalCount { return "Complete" }
        return "Queued"
    }

    private func summaryColor(_ activity: UpdateActivitySession) -> Color {
        if activity.failedCount > 0 { return .red }
        if activity.runningCount > 0 { return Theme.amber }
        if activity.warningCount > 0 { return Theme.amber }
        return .green
    }

    private func logText(for item: UpdateActivityItem) -> String {
        if item.log.isEmpty {
            switch item.status {
            case .queued: return "Waiting for this step to start."
            case .running: return "Waiting for output..."
            case .succeeded: return "Completed with no output."
            case .warning: return "Completed, but the recheck still needs attention."
            case .failed: return "Failed with no output."
            case .skipped: return "Skipped."
            }
        }
        return item.log.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func durationLabel(_ interval: TimeInterval) -> String {
        if interval < 1 { return "\(Int(interval * 1000))ms" }
        return String(format: "%.1fs", interval)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
