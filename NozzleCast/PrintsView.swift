import SwiftUI

/// Bambuddy's print queue and print history, with "How did it come out?" on finished prints.
struct PrintsView: View {
    enum Segment: Hashable { case queue, history }

    enum HistoryFilter: CaseIterable, Hashable {
        case all, unrated, good, rejected, failed

        var title: String {
            switch self {
            case .all: String(localized: "All", comment: "Print history filter")
            case .unrated: String(localized: "Needs Verdict", comment: "Print history filter: finished prints nobody rated yet")
            case .good: String(localized: "Good", comment: "Print history filter")
            case .rejected: String(localized: "Rejected", comment: "Print history filter")
            case .failed: String(localized: "Failed", comment: "Print history filter: failed or cancelled prints")
            }
        }

        func includes(_ record: PrintRecord) -> Bool {
            switch self {
            case .all: true
            case .unrated: record.isAwaitingVerdict
            case .good: record.verdict == .good
            case .rejected: record.verdict == .reject
            case .failed: record.outcome == .failed || record.outcome == .cancelled
            }
        }
    }

    @Environment(AppStore.self) private var store
    @Binding var selectedTab: RootTab
    @State private var segment: Segment = .queue
    @State private var historyFilter: HistoryFilter = .all
    @State private var pendingRemoval: QueuedPrint?
    @State private var pendingStart: QueuedPrint?

    private var isFirstLoad: Bool { !store.hasLoadedPrints && store.isLoadingPrints && !store.isShowingDemoData }

    private var filteredHistory: [PrintRecord] {
        store.printHistory.filter(historyFilter.includes)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    header

                    if store.isShowingDemoData {
                        DemoDataBanner(connectionStatus: store.connectionStatus) { selectedTab = .settings }
                            .padding(.horizontal, 16)
                    } else if let message = store.serverUnreachableMessage {
                        ServerUnreachableBanner(message: message) { selectedTab = .settings }
                            .padding(.horizontal, 16)
                    }

                    Picker(selection: $segment) {
                        Text("Queue", comment: "Prints tab segment").tag(Segment.queue)
                        Text("History", comment: "Prints tab segment").tag(Segment.history)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    if isFirstLoad {
                        VStack(spacing: 14) {
                            ProgressView().tint(NCColor.accentLight)
                            Text("Loading prints…")
                                .ncFont(size: 13, relativeTo: .footnote)
                                .foregroundStyle(NCColor.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    } else if let error = store.printsLoadError, !store.hasLoadedPrints {
                        emptyState(String(localized: "Couldn't load prints: \(error)", comment: "Prints tab load error"))
                    } else {
                        switch segment {
                        case .queue: queueContent
                        case .history: historyContent
                        }
                    }
                }
                .padding(.bottom, 100)
            }
            .background(NCColor.canvasBackground.ignoresSafeArea())
            .navigationBarHidden(true)
            .refreshable { await store.loadPrints() }
            .task { await store.loadPrints() }
            .confirmationDialog(
                Text("Remove from the queue?", comment: "Confirmation title for removing a queued print"),
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { item in
                Button(String(localized: "Remove \(item.name)", comment: "Confirm removing a queued print"), role: .destructive) {
                    store.removeQueuedPrint(item.id)
                }
            } message: { _ in
                Text("The file stays in Bambuddy; only the queued job is removed.", comment: "Explains what removing a queued print does")
            }
            .confirmationDialog(
                Text("Start this print?", comment: "Confirmation title for starting a staged queued print"),
                isPresented: Binding(get: { pendingStart != nil }, set: { if !$0 { pendingStart = nil } }),
                titleVisibility: .visible,
                presenting: pendingStart
            ) { item in
                Button(String(localized: "Start", comment: "Confirm starting a staged queued print")) {
                    store.startQueuedPrint(item.id)
                }
            } message: { item in
                Text("Bambuddy sends it to \(item.destination) as soon as the printer is free. Make sure the build plate is clear.", comment: "Explains what starting a staged print does")
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Prints")
                .ncFont(size: 34, weight: .bold, relativeTo: .largeTitle)
            Text(summary)
                .ncFont(size: 15, relativeTo: .subheadline)
                .foregroundStyle(NCColor.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var summary: AttributedString {
        let queued = store.queue.count
        let unrated = store.printHistory.filter(\.isAwaitingVerdict).count
        if unrated > 0 {
            return AttributedString(localized: "^[\(queued) job](inflect: true) queued · \(unrated) to rate", comment: "Prints tab header, e.g. '3 jobs queued · 2 to rate'")
        }
        return AttributedString(localized: "^[\(queued) job](inflect: true) queued", comment: "Prints tab header")
    }

    // MARK: Queue

    @ViewBuilder
    private var queueContent: some View {
        if store.queue.isEmpty {
            emptyState(String(localized: "Nothing queued. Jobs added to Bambuddy's print queue show up here.", comment: "Empty print queue"))
        } else {
            ForEach(store.queue) { item in
                QueueRow(
                    item: item,
                    startBlockedReason: startBlockedReason(item),
                    onStart: { pendingStart = item },
                    onRemove: { pendingRemoval = item }
                )
                .padding(.horizontal, 16)
            }
        }
    }

    private func startBlockedReason(_ item: QueuedPrint) -> String? {
        guard let printerID = item.printerID, store.printer(printerID)?.lacksDeveloperMode == true else { return nil }
        return String(localized: "Developer LAN mode is off on \(item.destination), so it won't accept a print from Bambuddy.", comment: "Why a queued print can't be started")
    }

    // MARK: History

    @ViewBuilder
    private var historyContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HistoryFilter.allCases, id: \.self) { filter in
                    FilterChip(title: filter.title, isActive: historyFilter == filter) { historyFilter = filter }
                }
            }
            .padding(.horizontal, 16)
        }

        if filteredHistory.isEmpty && !store.hasMorePrintHistory {
            emptyState(store.printHistory.isEmpty
                ? String(localized: "No prints yet.", comment: "Empty print history")
                : String(localized: "No prints match this filter.", comment: "Print history filter shows nothing"))
        } else {
            ForEach(filteredHistory) { record in
                HistoryRow(record: record)
                    .padding(.horizontal, 16)
            }
            if store.hasMorePrintHistory {
                // Pages in when scrolled to; a filter that matches few records still reaches older
                // ones because this row keeps appearing at the end.
                ProgressView()
                    .tint(NCColor.accentLight)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .task(id: store.printHistory.count) { await store.loadMorePrintHistory() }
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .ncFont(size: 13, relativeTo: .footnote)
            .foregroundStyle(NCColor.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 40)
    }
}

// MARK: - Rows

private struct QueueRow: View {
    var item: QueuedPrint
    var startBlockedReason: String?
    var onStart: () -> Void
    var onRemove: () -> Void
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PrintThumbnailView(key: item.id) { await store.queueThumbnail(for: item, maxPixelSize: 168) }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .ncFont(size: 15, weight: .semibold, relativeTo: .headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(item.destination)
                    .ncFont(size: 12.5, relativeTo: .caption)
                    .foregroundStyle(NCColor.textSecondary)
                PrintFacts(duration: item.estimatedDuration, grams: item.filamentGrams, type: item.filamentType, colorHex: item.filamentColorHex)
                statusLine
                if item.isStaged && item.status == .pending {
                    if let startBlockedReason {
                        Text(startBlockedReason)
                            .ncFont(size: 11.5, relativeTo: .caption2)
                            .foregroundStyle(NCColor.textTertiary)
                    } else {
                        Button(action: onStart) {
                            Label("Start", systemImage: "play.fill")
                                .ncFont(size: 13, weight: .semibold, relativeTo: .footnote)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(NCColor.accent))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.status == .pending {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NCColor.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("More", comment: "Queue job actions menu"))
            }
        }
        .padding(12)
        .glassCard()
        .contextMenu {
            if item.status == .pending { menuItems }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if item.isStaged && startBlockedReason == nil {
            Button(action: onStart) { Label("Start", systemImage: "play.fill") }
        }
        Button { store.moveQueuedPrint(item.id, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
            .disabled(!store.canMoveQueuedPrint(item.id, by: -1))
        Button { store.moveQueuedPrint(item.id, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
            .disabled(!store.canMoveQueuedPrint(item.id, by: 1))
        Button(role: .destructive, action: onRemove) { Label("Remove from Queue…", systemImage: "trash") }
    }

    @ViewBuilder
    private var statusLine: some View {
        Group {
            if item.status == .printing {
                Label("Printing now", systemImage: "printer.fill")
                    .foregroundStyle(NCColor.statusPrinting)
            } else if item.isStaged {
                Label("Staged · waits for Start", systemImage: "hand.raised.fill")
                    .foregroundStyle(NCColor.statusWarning)
            } else if let scheduledAt = item.scheduledAt, scheduledAt > Date() {
                Label("Scheduled \(scheduledAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar")
                    .foregroundStyle(NCColor.textSecondary)
            } else if let reason = item.waitingReason, !reason.isEmpty {
                Label(reason, systemImage: "clock")
                    .foregroundStyle(NCColor.textSecondary)
            } else {
                Label("Up next", systemImage: "clock")
                    .foregroundStyle(NCColor.textSecondary)
            }
        }
        .ncFont(size: 12, weight: .medium, relativeTo: .caption)
        .labelStyle(CompactLabelStyle())
        .padding(.top, 2)
    }
}

private struct HistoryRow: View {
    var record: PrintRecord
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                PrintThumbnailView(key: record.id) { await store.printThumbnail(for: record, maxPixelSize: 168) }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(record.name)
                            .ncFont(size: 15, weight: .semibold, relativeTo: .headline)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        OutcomeBadge(outcome: record.outcome)
                    }
                    Group {
                        if let finishedAt = record.finishedAt {
                            Text("\(record.printerName ?? "") · \(finishedAt.formatted(.relative(presentation: .named)))", comment: "Print history row: printer name · when it finished")
                        } else if let printerName = record.printerName {
                            Text(printerName)
                        }
                    }
                    .ncFont(size: 12.5, relativeTo: .caption)
                    .foregroundStyle(NCColor.textSecondary)
                    PrintFacts(duration: record.duration, grams: record.filamentGrams, type: record.filamentType, colorHex: record.filamentColorHex)
                    if let failureReason = record.failureReason, !failureReason.isEmpty {
                        Text(failureReason)
                            .ncFont(size: 12, relativeTo: .caption)
                            .foregroundStyle(NCColor.statusError)
                    }
                }
            }

            if record.acceptsVerdict && (record.verdict != nil || record.isAwaitingVerdict) {
                VerdictPicker(record: record)
            } else if let verdict = record.verdict {
                // An older run of a reprinted file: shown, but Bambuddy keeps one verdict per file
                // and it belongs to the newest run.
                VerdictBadge(verdict: verdict)
            }
        }
        .padding(12)
        .glassCard()
        .contextMenu {
            if record.acceptsVerdict {
                Button { store.setVerdict(.good, forPrint: record.id) } label: {
                    Label("Came Out Good", systemImage: "hand.thumbsup")
                }
                .disabled(record.verdict == .good)
                Button { store.setVerdict(.reject, forPrint: record.id) } label: {
                    Label("Reject", systemImage: "hand.thumbsdown")
                }
                .disabled(record.verdict == .reject)
                if record.verdict != nil {
                    Button { store.setVerdict(nil, forPrint: record.id) } label: {
                        Label("Clear Verdict", systemImage: "xmark")
                    }
                }
            }
        }
    }
}

// MARK: - Verdict

/// "How did it come out?" with Good / Reject. Tapping the chosen answer again clears it.
struct VerdictPicker: View {
    var record: PrintRecord
    var showsQuestion = true
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            if showsQuestion {
                Text(record.verdict == nil ? "How did it come out?" : "Came out", comment: "Post-print outcome question; after answering, labels the answer")
                    .ncFont(size: 13, weight: .medium, relativeTo: .footnote)
                    .foregroundStyle(NCColor.textSecondary)
                Spacer(minLength: 4)
            }
            option(.good, title: String(localized: "Good", comment: "Print verdict"), systemImage: "hand.thumbsup.fill", tint: NCColor.statusPrinting)
            option(.reject, title: String(localized: "Reject", comment: "Print verdict"), systemImage: "hand.thumbsdown.fill", tint: NCColor.statusError)
            if !showsQuestion { Spacer(minLength: 0) }
        }
        .sensoryFeedback(.selection, trigger: record.verdict)
    }

    private func option(_ verdict: PrintVerdict, title: String, systemImage: String, tint: Color) -> some View {
        let isSelected = record.verdict == verdict
        return Button {
            store.setVerdict(isSelected ? nil : verdict, forPrint: record.id)
        } label: {
            Label(title, systemImage: systemImage)
                .ncFont(size: 13, weight: .semibold, relativeTo: .footnote)
                .foregroundStyle(isSelected ? .white : tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(isSelected ? tint : tint.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct VerdictBadge: View {
    var verdict: PrintVerdict

    var body: some View {
        let isGood = verdict == .good
        Label(isGood ? String(localized: "Good", comment: "Print verdict") : String(localized: "Reject", comment: "Print verdict"),
              systemImage: isGood ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
            .ncFont(size: 12, weight: .semibold, relativeTo: .caption)
            .foregroundStyle(isGood ? NCColor.statusPrinting : NCColor.statusError)
    }
}

private struct OutcomeBadge: View {
    var outcome: PrintRecord.Outcome

    var body: some View {
        let (text, color): (String, Color) = switch outcome {
        case .completed: (String(localized: "Finished", comment: "Print history status"), NCColor.textTertiary)
        case .failed: (String(localized: "Failed", comment: "Print history status"), NCColor.statusError)
        case .cancelled: (String(localized: "Cancelled", comment: "Print history status"), NCColor.statusWarning)
        case .other(let raw): (raw.capitalized, NCColor.textTertiary)
        }
        Text(text)
            .ncFont(size: 11.5, weight: .semibold, relativeTo: .caption2)
            .foregroundStyle(color)
    }
}

// MARK: - Shared pieces

/// "2h 40m · ● PLA 38 g" — whichever of those facts are known.
private struct PrintFacts: View {
    var duration: TimeInterval?
    var grams: Double?
    var type: String?
    var colorHex: String?

    var body: some View {
        HStack(spacing: 6) {
            if let duration, duration > 0 {
                Text(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
            }
            if duration != nil, grams != nil || type != nil {
                Text("·")
            }
            if let colorHex, !colorHex.isEmpty {
                Circle().fill(Color(hex: colorHex)).frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
            }
            if let type, !type.isEmpty {
                Text(type)
            }
            if let grams, grams > 0 {
                Text("\(grams, format: .number.precision(.fractionLength(0))) g", comment: "Filament weight in grams")
            }
        }
        .ncFont(size: 12, relativeTo: .caption)
        .foregroundStyle(NCColor.textTertiary)
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 10.5, weight: .semibold))
            configuration.title
        }
    }
}

/// Plate thumbnail for a queued or past print, loaded once per row.
struct PrintThumbnailView: View {
    var key: String
    var size: CGFloat = 56
    var load: () async -> UIImage?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(NCColor.printerWell)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                Image(systemName: "cube.transparent")
                    .font(.system(size: size * 0.36))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(NCColor.printerWellBorder, lineWidth: 1)
        )
        .task(id: key) { image = await load() }
    }
}

#Preview {
    let store = AppStore(config: BambuddyConfig())
    PrintsView(selectedTab: .constant(.prints))
        .environment(store)
        .preferredColorScheme(.dark)
        .onAppear { store.loadMockData() }
}
