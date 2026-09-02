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

        var thumbnail: Data?
        if let attachmentURL = message.attachmentURL, let imageData = await Self.downloadImage(attachmentURL) {
            if let localURL = Self.writeTempFile(imageData, id: message.id),
               let attachment = try? UNNotificationAttachment(identifier: message.id, url: localURL) {
                content.attachments = [attachment]
            }
            thumbnail = Self.downscaledThumbnail(imageData)
            // Same full-size download used for the banner attachment, kept alongside the history
            // entry so the in-app Notifications list can show it too (that list reads the shared
            // history log directly, not the system's notification center).
            PushSharedStore.saveHistoryImage(imageData, id: message.id)
        }
        await Self.updateLiveActivity(matching: message, thumbnail: thumbnail)

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
    /// slug ("vic-h2c"). `PrintActivityAttributes.normalizedID` strips everything but
    /// letters/digits so both forms compare equal, and is shared with the app side so an
    /// activity either process creates or updates is found correctly by the other.
    ///
    /// Also the *only* mechanism that starts or ends a Live Activity when the app isn't
    /// foregrounded. `AppStore.refresh()` — the only other thing that manages activities — only
    /// runs while the app is open, so without this: a print starting with the app backgrounded
    /// would show no Live Activity at all until the app was next opened (confirmed as a real bug
    /// — the "Print Started" notification arrived fine, nothing else did), and a print completing
    /// overnight would leave one frozen on "Printing" indefinitely (also confirmed). Both are
    /// closed by reacting to Bambuddy's own push events here, which arrive regardless of app state.
    private static func updateLiveActivity(matching message: NtfyPushMessage, thumbnail: Data?) async {
        let haystack = PrintActivityAttributes.normalizedID((message.title ?? "") + " " + (message.message ?? ""))
        let terminalLabel = terminalStateLabel(forTitle: message.title ?? "")
        var matchedAny = false

        // Only `.active` activities count as a match — an already-ended one still lingers in
        // `.activities` through its dismissal window (up to 30 minutes), and without this a new
        // print starting on the same printer within that window would find the old, dismissing
        // activity, update it instead of starting a fresh one, and never show a new card at all.
        for activity in Activity<PrintActivityAttributes>.activities where activity.activityState == .active {
            guard haystack.contains(activity.attributes.printerID) else { continue }
            matchedAny = true
            var state = activity.content.state
            if let thumbnail { state.liveSnapshot = thumbnail }

            // Awaited, not fired as an unstructured Task: the extension process is liable to be
            // terminated shortly after this method returns and `deliver(content)` is called, so
            // an un-awaited update here would very likely never actually reach the system.
            if let terminalLabel {
                state.stateLabel = terminalLabel
                if terminalLabel == "Complete" {
                    state.progress = 1
                    state.estimatedEndAt = Date()
                }
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(1800)))
            } else {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }

        // No existing activity matched this printer, and this event says a print began: start
        // one. There's no progress/ETA/temperature data available here (only free-text push
        // content) — AppStore.refresh() fills those in with real numbers the next time the app is
        // opened; this just makes sure something accurate shows up immediately rather than
        // nothing at all.
        NSLog("NCDEBUG NSE start-check matchedAny=%d terminalLabel=%@ isStart=%d areActivitiesEnabled=%d title=%@",
              matchedAny, terminalLabel ?? "nil", isStartEvent(forTitle: message.title ?? ""),
              ActivityAuthorizationInfo().areActivitiesEnabled, message.title ?? "nil")

        guard !matchedAny, terminalLabel == nil,
              isStartEvent(forTitle: message.title ?? ""),
              let printerName = printerName(fromMessage: message.message ?? ""),
              ActivityAuthorizationInfo().areActivitiesEnabled
        else { return }

        let attributes = PrintActivityAttributes(printerID: PrintActivityAttributes.normalizedID(printerName), printerName: printerName)
        let now = Date()
        let state = PrintActivityAttributes.ContentState(
            progress: 0,
            stateLabel: "Printing",
            jobName: nil,
            startedAt: now,
            estimatedEndAt: nil,
            currentLayer: nil,
            totalLayers: nil,
            nozzleTempC: nil,
            bedTempC: nil,
            coverImage: nil,
            liveSnapshot: thumbnail
        )
        do {
            let activity = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
            NSLog("NCDEBUG NSE requested activity id=%@ state=%@", activity.id, String(describing: activity.activityState))
        } catch {
            NSLog("NCDEBUG NSE Activity.request failed: %@", String(describing: error))
        }
    }

    /// Bambuddy's titles for these are plain and consistent enough to substring-match: "Complete"
    /// and "Print Completed" both contain "complete", as does the later, harmless-to-also-match
    /// "Bed Cooldown Complete" (which only ever fires after printing is already done, so ending
    /// the activity again there is a no-op). Failure/stop titles aren't confirmed against real
    /// traffic yet, but Bambuddy's own event flags (on_print_failed, on_print_stopped) strongly
    /// imply similarly plain wording.
    private static func terminalStateLabel(forTitle title: String) -> String? {
        let t = title.lowercased()
        if t.contains("complete") { return "Complete" }
        if t.contains("fail") { return "Failed" }
        if t.contains("cancel") { return "Cancelled" }
        if t.contains("stop") { return "Stopped" }
        return nil
    }

    /// Matches Bambuddy's own "Print Started" as well as the separate OctoPrint/OctoEverywhere
    /// integration's bare "Started" (both real titles seen on the shared ntfy topic) — either one
    /// means the same real-world fact, that the print did start.
    private static func isStartEvent(forTitle title: String) -> Bool {
        title.lowercased().contains("start")
    }

    /// Bambuddy's message bodies consistently lead with "{Printer Name}: ..." — e.g.
    /// "Vic H2C: No AMS Version..." or "sam-p1s: Started". Extracting that prefix is the only
    /// way to get a printer name here at all, since ntfy messages carry no printer id.
    private static func printerName(fromMessage message: String) -> String? {
        guard let colonIndex = message.firstIndex(of: ":") else { return nil }
        let name = message[message.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
