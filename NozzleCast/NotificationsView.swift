import SwiftUI
import UserNotifications

/// In-app history of push notifications received via the Notification Service Extension,
/// read from the shared App Group log so it survives even notifications the user swiped away.
struct NotificationsView: View {
    @State private var entries: [PushSharedStore.HistoryEntry] = []

    var body: some View {
        List {
            if entries.isEmpty {
                Text("No notifications yet.")
                    .foregroundStyle(NCColor.textTertiary)
                    .listRowBackground(Color.clear)
            }
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 10) {
                    thumbnail(for: entry)
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
        .onAppear {
            entries = PushSharedStore.loadHistory()
            Task {
                await PushSharedStore.markAllRead()
                try? await UNUserNotificationCenter.current().setBadgeCount(0)
            }
        }
    }

    private func thumbnail(for entry: PushSharedStore.HistoryEntry) -> some View {
        HistoryThumbnail(entryID: entry.id)
    }
}

/// A notification's attached photo, loaded and decoded at display size off the main thread.
/// Previously every row read its full-size image from disk and decoded it synchronously inside
/// `body`, on the main thread, for a 52pt thumbnail — on every re-render of the list.
private struct HistoryThumbnail: View {
    var entryID: String
    @State private var image: UIImage?
    @State private var hasImage = true

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if hasImage {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(NCColor.cardFill)
            }
        }
        .frame(width: hasImage ? 52 : 0, height: hasImage ? 52 : 0)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: entryID) {
            guard let data = await Self.loadData(entryID) else {
                hasImage = false
                return
            }
            image = await ImageDownsampling.image(from: data, maxPixelSize: 52 * 3)
            hasImage = image != nil
        }
    }

    @concurrent
    private nonisolated static func loadData(_ id: String) async -> Data? {
        PushSharedStore.loadHistoryImage(id: id)
    }
}

#Preview {
    NotificationsView()
        .preferredColorScheme(.dark)
}
