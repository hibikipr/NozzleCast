import UserNotifications
import ActivityKit
import UIKit
import NozzleCastShared

/// Bambuddy's self-hosted ntfy server relays through the user's shared Firebase project as a
/// data-only push (no `aps.alert`), so iOS won't display anything unless something here builds
/// the notification content. Ported from the user's own ntfy app
/// (`ntfy-ios/ntfyNSE/NotificationService.swift`), trimmed to what Bambuddy's alerts actually
/// use: title/body/priority/attachment. Bambuddy attaches a live camera snapshot to most print
/// events (confirmed against real message history), so this also attaches that photo to the
/// visible notification and pushes a small thumbnail into the matching printer's Live Activity.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        bestAttemptContent = content

        NSLog("NCDEBUG NSE didReceive userInfo=%@", request.content.userInfo)

        guard let message = NtfyPushMessage(userInfo: request.content.userInfo) else {
            deliver(content)
            return
        }

        Task {
            guard let content = bestAttemptContent else { return }
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

        // Starting low and returning the first fit was the bug: these renders are tiny enough
        // that quality 0.5 nearly always fits under maxBytes on the very first try, so the loop
        // never got a chance to check whether 0.6-0.95 would also fit — spending only ~40% of
        // the already-safe byte budget for zero size benefit and looking needlessly pixelated.
        // Starting near the top and stepping down in finer increments still fails closed the
        // same way, but actually uses the bytes maxBytes already allotted. Confirmed against
        // nozzlecast-relay's identical fix (PR #24, v1.0.0-beta8): same pixel dimensions, same
        // byte ceiling, ~2x the bytes actually used.
        var quality: CGFloat = 0.95
        var jpeg = resized.jpegData(compressionQuality: quality)
        while let data = jpeg, data.count > maxBytes, quality > 0.05 {
            quality -= 0.05
            jpeg = resized.jpegData(compressionQuality: quality)
        }
        guard let jpeg, jpeg.count <= maxBytes else { return nil }
        return jpeg
    }

    /// Bambuddy's ntfy messages don't carry a printer id, only a name embedded in the title/body
    /// text — and inconsistently, sometimes the display name ("Vic H2C") and sometimes the raw
    /// slug ("vic-h2c"). `PrintActivityAttributes.normalizedID` strips everything but
    /// letters/digits so both forms compare equal, and is shared with the app side and with
    /// `nozzlecast-relay` (the self-hosted push-to-start relay, see `../ARCHITECTURE.md`) so an
    /// activity any of the three creates or updates is found correctly by the others.
    ///
    /// Only ever *updates* or *ends* an existing activity — never starts one, for the same
    /// foreground-only restriction documented on the app side.
    ///
    /// An earlier version of this comment stated as confirmed fact that this extension could
    /// never discover a push-to-start-created activity at all, citing
    /// `Activity<PrintActivityAttributes>.activities` staying empty at 0%, 50%, 75% and at
    /// "Print Completed" across a full print. That observation was real; the explanation was not.
    /// Push-to-start was silently broken at the time (the relay sent a module-qualified
    /// `attributes-type`), so no activity existed to be found. With that fixed, the app process
    /// does now discover these activities via `.activityUpdates` (confirmed 2026-09-07).
    ///
    /// Whether *this* extension does is untested. It's still a fresh OS process per push with no
    /// state carried between invocations, so it plausibly still finds nothing — but "never" is no
    /// longer an established fact, just an untested guess. Either way the relay's per-activity
    /// push is what actually carries update/end, so this path is a fallback, not the mechanism.
    ///
    /// The real fix for push-to-start-created activities is `PushNotificationManager`'s per-activity
    /// push token registration: each activity's own `pushTokenUpdates` token is sent to
    /// `nozzlecast-relay`'s `/register-activity`, and the relay pushes `update`/`end` events
    /// directly to that token via APNs — no local discovery needed on either side. Confirmed working
    /// end-to-end (start → progress → completion, all while locked) as of this writing.
    private static func updateLiveActivity(matching message: NtfyPushMessage, thumbnail: Data?) async {
        // Per Apple's guidance ("make it easy for people to turn them off in your app"), Settings
        // exposes this toggle. Turning it off here just stops this push-driven path from touching
        // activities further — `PrintLiveActivityManager.sync()` (the main app, on its next
        // refresh) is what actually ends any that are already running.
        guard PushSharedStore.liveActivitiesEnabled else { return }
        let haystack = PrintActivityAttributes.normalizedID((message.title ?? "") + " " + (message.message ?? ""))
        let terminalLabel = terminalStateLabel(forTitle: message.title ?? "")
        let progress = progressFraction(forTitle: message.title ?? "")
        let remainingMinutes = remainingMinutes(fromMessage: message.message ?? "")

        let allActivities = Activity<PrintActivityAttributes>.activities
        NSLog("NCDEBUG NSE update haystack=%@ terminalLabel=%@ allActivities=%@", haystack, terminalLabel ?? "nil",
              allActivities.map { "id=\($0.id) printerID=\($0.attributes.printerID) state=\($0.activityState)" }.description)

        // Only `.active` activities count as a match — an already-ended one still lingers in
        // `.activities` through its dismissal window (up to 30 minutes), and without this a new
        // print starting on the same printer within that window would find the old, dismissing
        // activity, update it instead of the relay's fresh one, and never show a new card at all.
        for activity in allActivities where activity.activityState == .active {
            guard haystack.contains(activity.attributes.printerID) else {
                NSLog("NCDEBUG NSE no match: printerID=%@ not in haystack", activity.attributes.printerID)
                continue
            }
            NSLog("NCDEBUG NSE matched activity id=%@ printerID=%@", activity.id, activity.attributes.printerID)
            var state = activity.content.state
            // A live camera frame on the Lock Screen is visible to anyone who picks up the phone
            // — Apple's guidance calls out letting people configure whether sensitive content
            // like this shows there. Skips assignment entirely rather than clearing an existing
            // frame, matching how `coverImage` is already left alone when a fresh one isn't sent.
            if let thumbnail, PushSharedStore.liveActivityCameraPreviewEnabled { state.liveSnapshot = thumbnail }

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
                NSLog("NCDEBUG NSE ended activity id=%@ resultingState=%@", activity.id, String(describing: activity.activityState))
            } else {
                // Bambuddy's progress titles carry the real percentage and remaining time (e.g.
                // "Print 70% Complete" / "...Remaining: 4m") — previously ignored entirely, which
                // left the Live Activity frozen at whatever value it started with (0% from the
                // relay's push-to-start, since it has no telemetry access) until the app was next
                // opened and did its own foreground refresh against Bambuddy's real API. Parsing
                // these directly out of the push text closes that gap without needing the
                // extension to make any of its own network calls.
                if let progress {
                    state.progress = progress
                    if let remainingMinutes {
                        state.estimatedEndAt = Date().addingTimeInterval(TimeInterval(remainingMinutes * 60))
                    }
                }
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    /// Bambuddy's titles for these are plain and consistent enough to substring-match: "Complete"
    /// and "Print Completed" both contain "complete", as does the later, harmless-to-also-match
    /// "Bed Cooldown Complete" (which only ever fires after printing is already done, so ending
    /// the activity again there is a no-op). Failure/stop titles aren't confirmed against real
    /// traffic yet, but Bambuddy's own event flags (on_print_failed, on_print_stopped) strongly
    /// imply similarly plain wording.
    ///
    /// Critical guard: Bambuddy's own progress-milestone titles ("Print 50% Complete") *also*
    /// contain the word "complete" — without excluding any title carrying a percentage, every
    /// progress push was mistaken for the print's actual completion, ending the Live Activity at
    /// the very first milestone. Confirmed as a real bug in practice: progress stayed frozen at
    /// its initial value (the update branch was never reached) and the real final "Print
    /// Completed" push later had no visible effect (the activity was already `.ended`, so the
    /// `.active`-only filter in `updateLiveActivity` skipped it entirely). A percentage in the
    /// title unambiguously marks it as a progress update, never the terminal event.
    ///
    /// Same problem, different title: Bambuddy's "First Layer Complete" milestone (fired almost
    /// immediately after a print starts) also contains "complete" but carries no percentage, so
    /// the guard above doesn't catch it — confirmed as a second real instance of this exact bug:
    /// it ended the Live Activity within moments of starting, before any of the print's real
    /// progress could ever be applied. Excluding any title mentioning "layer" closes this
    /// specifically, since none of Bambuddy's genuine completion titles do.
    private static func terminalStateLabel(forTitle title: String) -> String? {
        guard progressFraction(forTitle: title) == nil else { return nil }
        let t = title.lowercased()
        guard !t.contains("layer") else { return nil }
        if t.contains("complete") { return "Complete" }
        if t.contains("fail") { return "Failed" }
        if t.contains("cancel") { return "Cancelled" }
        if t.contains("stop") { return "Stopped" }
        return nil
    }

    /// Bambuddy's progress titles are consistently "Print {N}% Complete" — pulls the first
    /// integer immediately before a "%" and normalizes it to a 0...1 fraction for `ContentState`.
    private static func progressFraction(forTitle title: String) -> Double? {
        guard let match = title.range(of: #"\d+(?=%)"#, options: .regularExpression),
              let percent = Int(title[match])
        else { return nil }
        return Double(percent) / 100
    }

    /// Bambuddy's progress messages consistently end with "...Remaining: {N}m" — pulls the
    /// integer minute count so the Live Activity's countdown can be recomputed from a push
    /// alone, without the extension making any network call of its own.
    private static func remainingMinutes(fromMessage message: String) -> Int? {
        guard let match = message.range(of: #"(?<=Remaining: )\d+(?=m)"#, options: .regularExpression) else { return nil }
        return Int(message[match])
    }
}
