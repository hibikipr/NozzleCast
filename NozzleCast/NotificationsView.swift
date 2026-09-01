import SwiftUI

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
                        PushSharedStore.clearHistory()
                        entries = []
                    }
                }
            }
        }
        .onAppear { entries = PushSharedStore.loadHistory() }
    }

    @ViewBuilder
    private func thumbnail(for entry: PushSharedStore.HistoryEntry) -> some View {
        if let data = PushSharedStore.loadHistoryImage(id: entry.id), let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
