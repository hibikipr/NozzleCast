import UserNotifications
import ActivityKit
import UIKit

/// Bambuddy's self-hosted ntfy server relays through the user's shared Firebase project as a
/// data-only push (no `aps.alert`), so iOS won't display anything unless something here builds
/// the notification content. Ported from the user's own ntfy app
/// (`ntfy-ios/ntfyNSE/NotificationService.swift`), trimmed to what Bambuddy's alerts actually
/// use: title/body/priority/attachment. Bambuddy attaches a live camera snapshot to most print
/// events (confirmed against real message history), so this also attaches that photo to the
/// visible notification and pushes a small thumbnail into the matching printer's Live Activity.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        bestAttemptContent = content

        guard let message = NtfyPushMessage(userInfo: request.content.userInfo) else {
            deliver(content)
            return
        }

        Task {
            switch message.event {
            case "poll_request":
                await handlePollRequest(message, content: content)
            default:
                await handleMessage(message, content: content)
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let bestAttemptContent {
            deliver(bestAttemptContent)
        }
    }

    private func deliver(_ content: UNNotificationContent) {
        contentHandler?(content)
        contentHandler = nil
    }

    private func handleMessage(_ message: NtfyPushMessage, content: UNMutableNotificationContent) async {
        await apply(message, to: content)
        deliver(content)
    }

    private func handlePollRequest(_ message: NtfyPushMessage, content: UNMutableNotificationContent) async {
        guard let config = PushSharedStore.loadNtfyConfig(),
              let polled = await NtfyPoller.poll(baseUrl: config.server, topic: message.topic, messageID: message.pollID ?? message.id, authToken: config.authToken)
        else {
            deliver(content)
            return
        }
        await apply(polled, to: content)
        deliver(content)
    }

    private func apply(_ message: NtfyPushMessage, to content: UNMutableNotificationContent) async {
        content.title = message.title?.isEmpty == false ? message.title! : message.topic
        content.body = message.message ?? ""
        content.threadIdentifier = message.topic
        content.sound = .default

        switch message.priority ?? 3 {
        case 5:
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
        case 4:
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 0.8
        case 1, 2:
            content.interruptionLevel = .passive
            content.relevanceScore = 0.3
        default:
            content.interruptionLevel = .active
            content.relevanceScore = 0.5
        }

        if let attachmentURL = message.attachmentURL, let imageData = await Self.downloadImage(attachmentURL) {
            if let localURL = Self.writeTempFile(imageData, id: message.id),
               let attachment = try? UNNotificationAttachment(identifier: message.id, url: localURL) {
                content.attachments = [attachment]
            }
            if let thumbnail = Self.downscaledThumbnail(imageData) {
                await Self.updateLiveActivity(matching: message, thumbnail: thumbnail)
            }
            // Same full-size download used for the banner attachment, kept alongside the history
            // entry so the in-app Notifications list can show it too (that list reads the shared
            // history log directly, not the system's notification center).
            PushSharedStore.saveHistoryImage(imageData, id: message.id)
        }

        PushSharedStore.appendHistory(.init(
            id: message.id,
            title: content.title,
            body: content.body,
            receivedAt: Date(),
            isRead: false
        ))

        // The app icon's badge count, so unread pushes are visible without opening the app —
        // recomputed from the log rather than incremented, since this and the main app's own
        // "mark all read" both write the same file and an increment could drift out of sync.
        content.badge = NSNumber(value: PushSharedStore.unreadCount())
    }

    private static func downloadImage(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        if let authToken = PushSharedStore.loadNtfyConfig()?.authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }

    private static func writeTempFile(_ data: Data, id: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).jpg")
        guard (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    /// Downscales to a tiny JPEG for the Live Activity's content state. ActivityKit's real budget
    /// for the *whole* serialized content state is close to 4KB, and a Data field costs ~33% more
    /// than its raw byte count once base64-encoded into that JSON — plus progress/dates/strings
    /// already take a share; a 3KB image once blew that budget and the system ended the activity
    /// outright rather than just dropping the update. The real bug behind every "still won't fit"
    /// symptom: `UIGraphicsImageRenderer` defaults its render scale to the device's screen scale
    /// (2x/3x), so a "40pt" render was actually rasterizing up to 9x the intended pixel count no
    /// matter how low the JPEG quality went — pinning `format.scale = 1` fixes the real cause;
    /// the byte cap only ever needed to be this generous to mask that.
    private static func downscaledThumbnail(_ data: Data, maxDimension: CGFloat = 40, maxBytes: Int = 1300) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(maxDimension / max(image.size.width, image.size.height), 1)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        var quality: CGFloat = 0.5
        var jpeg = resized.jpegData(compressionQuality: quality)
        while let data = jpeg, data.count > maxBytes, quality > 0.1 {
            quality -= 0.1
            jpeg = resized.jpegData(compressionQuality: quality)
        }
        guard let jpeg, jpeg.count <= maxBytes else { return nil }
        return jpeg
    }

    /// Bambuddy's ntfy messages don't carry a printer id, only a name embedded in the title/body
    /// text — and inconsistently, sometimes the display name ("Vic H2C") and sometimes the raw
    /// slug ("vic-h2c"). Stripping non-alphanumerics before comparing matches both forms.
    private static func updateLiveActivity(matching message: NtfyPushMessage, thumbnail: Data) async {
        let haystack = normalize((message.title ?? "") + " " + (message.message ?? ""))
        for activity in Activity<PrintActivityAttributes>.activities {
            guard haystack.contains(normalize(activity.attributes.printerName)) else { continue }
            var state = activity.content.state
            state.liveSnapshot = thumbnail
            // Awaited, not fired as an unstructured Task: the extension process is liable to be
            // terminated shortly after this method returns and `deliver(content)` is called, so
            // an un-awaited update here would very likely never actually reach the system.
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
