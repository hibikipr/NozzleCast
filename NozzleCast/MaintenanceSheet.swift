import SwiftUI

/// A printer's maintenance tasks from Bambuddy's tracker: what's due, what's coming up, and a way
/// to record a task as done.
struct MaintenanceSheet: View {
    var printerID: String
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDone: MaintenanceTask?

    private var printer: Printer? { store.printer(printerID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let printer, !printer.maintenanceTasks.isEmpty {
                        if let hours = printer.totalPrintHours {
                            Text("\(Int(hours)) print hours in total", comment: "Maintenance sheet: the printer's accumulated print hours")
                                .ncFont(size: 13, relativeTo: .footnote)
                                .foregroundStyle(NCColor.textSecondary)
                                .padding(.bottom, 4)
                        }
                        ForEach(printer.maintenanceTasks) { task in
                            MaintenanceTaskRow(task: task) { pendingDone = task }
                        }
                    } else {
                        Text("No maintenance tasks are set up for this printer. Add them in Bambuddy's Maintenance page.", comment: "Maintenance sheet empty state")
                            .ncFont(size: 13, relativeTo: .footnote)
                            .foregroundStyle(NCColor.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(16)
            }
            .background(Color(hex: "#212121").ignoresSafeArea())
            .navigationTitle(Text("\(printer?.name ?? "") · Maintenance", comment: "Maintenance sheet title, e.g. 'Sam P1S · Maintenance'"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await store.refresh() }
            .confirmationDialog(
                Text("Mark as done?", comment: "Confirmation title for recording a maintenance task"),
                isPresented: Binding(get: { pendingDone != nil }, set: { if !$0 { pendingDone = nil } }),
                titleVisibility: .visible,
                presenting: pendingDone
            ) { task in
                Button(String(localized: "Mark \(task.name) Done", comment: "Confirm recording a maintenance task as done")) {
                    store.performMaintenance(printerID: printerID, taskID: task.id)
                }
            } message: { _ in
                Text("Bambuddy records it as done now and restarts its interval.", comment: "Explains marking a maintenance task done")
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct MaintenanceTaskRow: View {
    var task: MaintenanceTask
    var markDone: () -> Void

    private var tint: Color {
        task.isDue ? NCColor.statusError : task.isWarning ? NCColor.statusWarning : NCColor.statusPrinting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: task.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(tint.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name)
                        .ncFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(.white)
                    Text(statusText)
                        .ncFont(size: 12.5, weight: .medium, relativeTo: .caption)
                        .foregroundStyle(task.isDue || task.isWarning ? tint : NCColor.textSecondary)
                }
                Spacer(minLength: 8)
                if let wikiURL = task.wikiURL {
                    Link(destination: wikiURL) {
                        Image(systemName: "book")
                            .font(.system(size: 15))
                            .foregroundStyle(NCColor.textSecondary)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(Text("How to do this", comment: "Opens the maintenance task's guide"))
                }
            }

            ProgressBar(progress: task.progress, tint: tint)

            HStack {
                Text(intervalText)
                    .ncFont(size: 12, relativeTo: .caption)
                    .foregroundStyle(NCColor.textTertiary)
                Spacer(minLength: 8)
                Button(action: markDone) {
                    Label("Mark Done", systemImage: "checkmark")
                        .ncFont(size: 13, weight: .semibold, relativeTo: .footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(task.isDue || task.isWarning ? NCColor.accent : Color.white.opacity(0.08)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 16)
    }

    /// "Due in 48 print hours", "Overdue by 3 days", "Due now".
    private var statusText: String {
        let amount = abs(task.remaining)
        let rounded = Int(amount.rounded())
        switch task.interval {
        case .printHours:
            if task.isDue && rounded == 0 { return String(localized: "Due now", comment: "Maintenance task is due") }
            return task.remaining < 0
                ? String(localized: "Overdue by \(rounded) print hours", comment: "Maintenance task overdue, in print hours")
                : String(localized: "Due in \(rounded) print hours", comment: "Maintenance task due in print hours")
        case .days:
            if task.isDue && rounded == 0 { return String(localized: "Due now", comment: "Maintenance task is due") }
            return task.remaining < 0
                ? Self.inflected(AttributedString(localized: "Overdue by ^[\(rounded) day](inflect: true)", comment: "Maintenance task overdue, in days"))
                : Self.inflected(AttributedString(localized: "Due in ^[\(rounded) day](inflect: true)", comment: "Maintenance task due in days"))
        }
    }

    /// Automatic grammar agreement ("1 day" / "2 days") only happens in an AttributedString.
    private static func inflected(_ text: AttributedString) -> String {
        String(text.inflected().characters)
    }

    /// "Every 50 print hours · done 2 days ago"
    private var intervalText: String {
        let every: String = switch task.interval {
        case .printHours(let hours): String(localized: "Every \(Int(hours.rounded())) print hours", comment: "Maintenance interval in print hours")
        case .days(let days): Self.inflected(AttributedString(localized: "Every ^[\(Int(days.rounded())) day](inflect: true)", comment: "Maintenance interval in days"))
        }
        guard let last = task.lastPerformedAt else { return every }
        return String(localized: "\(every) · done \(last.formatted(.relative(presentation: .named)))", comment: "Maintenance interval and when the task was last done")
    }
}
