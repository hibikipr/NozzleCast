import SwiftUI
import UserNotifications

/// In-app history of push notifications received via the Notification Service Extension,
/// read from the shared App Group log so it survives even notifications the user swiped away.
///
/// A notification's photo opens full screen on a tap. Swiping an entry left mutes alerts with
/// its exact title and body (a printer without Developer LAN mode repeats "MQTT Command
/// verification failed" on every command it ignores); the extension then delivers those
/// silently and keeps them out of this list, until they're unmuted from Muted Alerts.
struct NotificationsView: View {
    @State private var entries: [PushSharedStore.HistoryEntry] = []
    @State private var mutedAlerts: [PushSharedStore.MutedAlert] = []
    @State private var viewingImage: ViewingImage?

    var body: some View {
        List {
            if !mutedAlerts.isEmpty {
                NavigationLink {
                    MutedAlertsView(mutedAlerts: $mutedAlerts)
                } label: {
                    Label {
                        Text("Muted Alerts", comment: "Row opening the list of muted alerts")
                            .foregroundStyle(.white)
                    } icon: {
                        Image(systemName: "bell.slash").foregroundStyle(NCColor.textTertiary)
                    }
                    .badge(mutedAlerts.count)
                }
                .listRowBackground(NCColor.cardFill)
            }
            if entries.isEmpty {
                Text("No notifications yet.")
                    .foregroundStyle(NCColor.textTertiary)
                    .listRowBackground(Color.clear)
            }
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 12) {
                    HistoryThumbnail(entryID: entry.id) {
                        viewingImage = ViewingImage(id: entry.id)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                            .ncFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                            .foregroundStyle(.white)
                        Text(entry.body)
                            .ncFont(size: 13, relativeTo: .footnote)
                            .foregroundStyle(NCColor.textSecondary)
                        Text(entry.receivedAt, style: .relative)
                            .ncFont(size: 11, relativeTo: .caption2)
                            .foregroundStyle(NCColor.textTertiary)
                    }
                }
                .padding(.vertical, 2)
                .listRowBackground(NCColor.cardFill)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        mute(entry)
                    } label: {
                        Label(String(localized: "Mute", comment: "Swipe action: stop showing alerts like this one"), systemImage: "bell.slash")
                    }
                    .tint(NCColor.statusWarning)
                }
                .contextMenu {
                    Button {
                        mute(entry)
                    } label: {
                        Label(String(localized: "Mute Alerts Like This", comment: "Notification context menu: stop showing alerts with this title and text"), systemImage: "bell.slash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(NCColor.canvasBackground.ignoresSafeArea())
        .navigationTitle("Notifications")
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        Task {
                            await PushSharedStore.clearHistory()
                        }
                        entries = []
                    }
                }
            }
        }
        .fullScreenCover(item: $viewingImage) { viewing in
            NotificationImageViewer(entryID: viewing.id)
        }
        .onAppear {
            entries = PushSharedStore.loadHistory()
            mutedAlerts = PushSharedStore.mutedAlerts
            Task {
                await PushSharedStore.markAllRead()
                try? await UNUserNotificationCenter.current().setBadgeCount(0)
            }
        }
    }

    private func mute(_ entry: PushSharedStore.HistoryEntry) {
        let alert = PushSharedStore.MutedAlert(title: entry.title, body: entry.body)
        guard !mutedAlerts.contains(alert) else { return }
        mutedAlerts.append(alert)
        PushSharedStore.mutedAlerts = mutedAlerts
        withAnimation {
            entries.removeAll { $0.title == entry.title && $0.body == entry.body }
        }
        Task {
            await PushSharedStore.removeHistory(title: entry.title, body: entry.body)
            await RelayAlertClient.syncMutes()
        }
    }

    private struct ViewingImage: Identifiable {
        var id: String
    }
}

/// The alerts muted from the Notifications list, to unmute.
private struct MutedAlertsView: View {
    @Binding var mutedAlerts: [PushSharedStore.MutedAlert]

    var body: some View {
        List {
            Section {
                ForEach(mutedAlerts, id: \.self) { alert in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(alert.title)
                                .ncFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                                .foregroundStyle(.white)
                            Text(alert.body)
                                .ncFont(size: 13, relativeTo: .footnote)
                                .foregroundStyle(NCColor.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Button(String(localized: "Unmute", comment: "Button: show a muted alert again")) {
                            withAnimation { mutedAlerts.removeAll { $0 == alert } }
                            PushSharedStore.mutedAlerts = mutedAlerts
                            Task { await RelayAlertClient.syncMutes() }
                        }
                        .buttonStyle(.borderless)
                        .tint(NCColor.accentLight)
                    }
                    .listRowBackground(NCColor.cardFill)
                }
            } footer: {
                Text("These arrive silently and stay out of the Notifications list.", comment: "Footer under the muted alerts")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(NCColor.canvasBackground.ignoresSafeArea())
        .navigationTitle(String(localized: "Muted Alerts", comment: "Title of the muted alerts list"))
    }
}

/// A notification's attached photo, loaded and decoded at display size off the main thread.
/// Previously every row read its full-size image from disk and decoded it synchronously inside
/// `body`, on the main thread, for a thumbnail — on every re-render of the list. A tap opens it
/// full screen.
private struct HistoryThumbnail: View {
    var entryID: String
    var onOpen: () -> Void
    @State private var image: UIImage?
    @State private var hasImage = true

    private static let size: CGFloat = 72

    var body: some View {
        Button(action: onOpen) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if hasImage {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(NCColor.cardFill)
                }
            }
            .frame(width: hasImage ? Self.size : 0, height: hasImage ? Self.size : 0)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(image == nil)
        .accessibilityLabel(Text("Open photo", comment: "Accessibility label for a notification's photo"))
        .task(id: entryID) {
            guard let data = await loadHistoryImageData(entryID) else {
                hasImage = false
                return
            }
            image = await ImageDownsampling.image(from: data, maxPixelSize: Self.size * 3)
            hasImage = image != nil
        }
    }
}

/// A notification's photo at full size, to zoom into.
private struct NotificationImageViewer: View {
    var entryID: String
    @State private var image: UIImage?

    var body: some View {
        ZoomableImageViewer(image: image)
            .task(id: entryID) {
                guard let data = await loadHistoryImageData(entryID) else { return }
                image = await ImageDownsampling.image(from: data, maxPixelSize: nil)
            }
    }
}

@concurrent
private nonisolated func loadHistoryImageData(_ id: String) async -> Data? {
    PushSharedStore.loadHistoryImage(id: id)
}

#Preview {
    NotificationsView()
        .preferredColorScheme(.dark)
}
