import UserNotifications
import ActivityKit
import UIKit
import ImageIO
import UniformTypeIdentifiers
import os
import NozzleCastShared

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Bambuddy's self-hosted ntfy server relays through the user's shared Firebase project as a
/// data-only push (no `aps.alert`), so iOS won't display anything unless something here builds
/// the notification content. Ported from the user's own ntfy app
/// (`ntfy-ios/ntfyNSE/NotificationService.swift`), trimmed to what Bambuddy's alerts actually
/// use: title/body/priority/attachment. Bambuddy attaches a live camera snapshot to most print
/// events (confirmed against real message history), so this also attaches that photo to the
/// visible notification. (It used to push a thumbnail of it into the Live Activity too; that
/// shows the print's cover only now.)
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var contentHandler: ((UNNotificationContent) -> Void)?
        var bestAttemptContent: UNMutableNotificationContent?
        var inFlightTask: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private static let maxImageBytes = 8 * 1024 * 1024

    static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        state.withLockUnchecked { state in
            state.contentHandler = contentHandler
            state.bestAttemptContent = content
            state.inFlightTask = nil
        }

        NSELog.push.debug("NSE didReceive userInfo=\(String(describing: request.content.userInfo), privacy: .private)")

        let boxedContent = UncheckedSendable(content)

        // An alert the relay forwarded from Bambuddy's webhook: title and body are already in it.
        if let relayAlert = request.content.userInfo["nozzlecast"] as? [String: Any] {
            let alertID = relayAlert["alertID"] as? String
            let photoID = relayAlert["photoID"] as? String
            startInFlightTask {
                await self.handleRelayAlert(alertID: alertID, photoID: photoID, content: boxedContent.value)
            }
            return
        }

        guard let message = NtfyPushMessage(userInfo: request.content.userInfo) else {
            deliver(content)
            return
        }

        startInFlightTask {
            switch message.event {
            case "poll_request":
                await self.handlePollRequest(message, content: boxedContent.value)
            case "message":
                await self.handleMessage(message, content: boxedContent.value)
            default:
                self.deliver(boxedContent.value)
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        let (handler, fallbackContent, task) = state.withLockUnchecked { state -> (((UNNotificationContent) -> Void)?, UNNotificationContent?, Task<Void, Never>?) in
            let handler = state.contentHandler
            state.contentHandler = nil
            let fallbackContent = (state.bestAttemptContent?.copy() as? UNNotificationContent) ?? state.bestAttemptContent
            state.bestAttemptContent = nil
            let task = state.inFlightTask
            state.inFlightTask = nil
            return (handler, fallbackContent, task)
        }
        task?.cancel()
        if let handler, let fallbackContent {
            handler(fallbackContent)
        }
    }

    private func startInFlightTask(_ operation: @escaping @Sendable () async -> Void) {
        let task = Task {
            guard !Task.isCancelled else { return }
            await operation()
        }
        state.withLock { state in
            if state.contentHandler != nil {
                state.inFlightTask = task
            } else {
                task.cancel()
            }
        }
    }

    private func deliver(_ content: UNNotificationContent) {
        let handler = state.withLockUnchecked { state -> ((UNNotificationContent) -> Void)? in
            let handler = state.contentHandler
            state.contentHandler = nil
            state.bestAttemptContent = nil
            state.inFlightTask = nil
            return handler
        }
        handler?(content)
    }

    private func handleMessage(_ message: NtfyPushMessage, content: UNMutableNotificationContent) async {
        await apply(message, to: content)
        guard !Task.isCancelled else { return }
        deliver(content)
    }

    private func handlePollRequest(_ message: NtfyPushMessage, content: UNMutableNotificationContent) async {
        guard let config = PushSharedStore.loadNtfyConfig(),
              let polled = await NtfyPoller.poll(baseUrl: config.server, topic: message.topic, messageID: message.pollID ?? message.id, authToken: config.authToken)
        else {
            guard !Task.isCancelled else { return }
            deliver(content)
            return
        }
        guard !Task.isCancelled else { return }
        await apply(polled, to: content)
        guard !Task.isCancelled else { return }
        deliver(content)
    }

    private func apply(_ message: NtfyPushMessage, to content: UNMutableNotificationContent) async {
        content.title = message.title?.isEmpty == false ? message.title! : message.topic
        content.body = message.message ?? ""
        content.threadIdentifier = message.topic
        content.sound = .default

        // Muted from the app's Notifications list: no sound, no text, no history entry and no
        // badge bump. An extension without Apple's notification-filtering entitlement can't drop
        // a push outright; an empty, silent, passive one is as close as it gets.
        if silenceIfMuted(content) { return }

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

        // Logged before the photo: a slow download can outlast the extension's time, and the
        // alert should still reach the in-app list and the badge.
        let unreadCount = await PushSharedStore.appendHistory(.init(
            id: message.id,
            title: content.title,
            body: content.body,
            receivedAt: Date(),
            isRead: false
        ))
        content.badge = NSNumber(value: unreadCount)
        guard !Task.isCancelled else { return }

        if let attachmentURL = message.attachmentURL, let image = await Self.downloadImage(attachmentURL) {
            guard !Task.isCancelled else { return }
            if let attachment = Self.makeAttachment(from: image.data, id: message.id, mimeType: image.mimeType) {
                content.attachments = [attachment]
            }
            // Same full-size download used for the banner attachment, kept alongside the history
            // entry so the in-app Notifications list can show it too (that list reads the shared
            // history log directly, not the system's notification center).
            PushSharedStore.saveHistoryImage(image.data, id: message.id)
        }
        guard !Task.isCancelled else { return }
        await Self.updateLiveActivity(matching: message)
    }

    /// Muted from the app's Notifications list: no sound, no text, no history entry and no badge
    /// bump. An extension without Apple's notification-filtering entitlement can't drop a push
    /// outright; an empty, silent, passive one is as close as it gets. (Through the relay, a muted
    /// alert isn't pushed at all; this covers ntfy, and a mute that hasn't reached the relay yet.)
    private func silenceIfMuted(_ content: UNMutableNotificationContent) -> Bool {
        guard PushSharedStore.isMuted(title: content.title, body: content.body) else { return false }
        content.title = ""
        content.body = ""
        content.sound = nil
        content.interruptionLevel = .passive
        content.relevanceScore = 0
        content.badge = NSNumber(value: PushSharedStore.unreadCount())
        return true
    }

    /// A Bambuddy alert the relay pushed (`RelayAlertClient`), with the alert and photo ids from its
    /// `nozzlecast` payload (`{ alertID, event, printer, photoID }`). The relay sets the alert's text, sound and
    /// interruption level; this adds the photo (kept on the relay), logs it to the in-app history
    /// and sets the badge, as for an ntfy message. No Live Activity work: the relay already drives
    /// those.
    private func handleRelayAlert(alertID: String?, photoID: String?, content: UNMutableNotificationContent) async {
        if silenceIfMuted(content) {
            deliver(content)
            return
        }
        let id = alertID ?? UUID().uuidString
        // Logged before the photo: a slow download can outlast the extension's time, and the
        // alert should still reach the in-app list and the badge.
        let unreadCount = await PushSharedStore.appendHistory(.init(id: id, title: content.title, body: content.body, receivedAt: Date(), isRead: false))
        content.badge = NSNumber(value: unreadCount)
        guard !Task.isCancelled else { return }

        if let photoID, let image = await Self.downloadRelayPhoto(photoID) {
            guard !Task.isCancelled else { return }
            if let attachment = Self.makeAttachment(from: image.data, id: id, mimeType: image.mimeType) {
                content.attachments = [attachment]
            }
            PushSharedStore.saveHistoryImage(image.data, id: id)
        }
        guard !Task.isCancelled else { return }
        deliver(content)
    }

    private static func downloadRelayPhoto(_ photoID: String) async -> (data: Data, mimeType: String?)? {
        guard let relay = PushSharedStore.loadRelayConnection() else { return nil }
        var request = URLRequest(url: relay.url.appendingPathComponent("alert-photo").appendingPathComponent(photoID))
        request.setValue("Bearer \(relay.authSecret)", forHTTPHeaderField: "Authorization")
        return await downloadData(for: request, allowedStatusCodes: 200..<201)
    }

    private static func downloadImage(_ url: URL) async -> (data: Data, mimeType: String?)? {
        var request = URLRequest(url: url)
        if let config = PushSharedStore.loadNtfyConfig(),
           let authToken = config.authToken, !authToken.isEmpty,
           let serverURL = URL(string: config.server.trimmingCharacters(in: .whitespacesAndNewlines)),
           matchesServerOrigin(url, configuredServerURL: serverURL) {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        return await downloadData(for: request, allowedStatusCodes: 200..<300)
    }

    private static func matchesServerOrigin(_ url: URL, configuredServerURL: URL) -> Bool {
        guard let urlScheme = url.scheme?.lowercased(),
              let serverScheme = configuredServerURL.scheme?.lowercased(),
              urlScheme == serverScheme,
              let urlHost = url.host?.lowercased(),
              let serverHost = configuredServerURL.host?.lowercased(),
              urlHost == serverHost
        else { return false }
        return effectivePort(for: url, scheme: urlScheme) == effectivePort(for: configuredServerURL, scheme: serverScheme)
    }

    private static func effectivePort(for url: URL, scheme: String) -> Int? {
        if let port = url.port { return port }
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func downloadData(for request: URLRequest, allowedStatusCodes: Range<Int>) async -> (data: Data, mimeType: String?)? {
        let delegate = ImageDownloadDelegate(maxBytes: maxImageBytes, allowedStatusCodes: allowedStatusCodes)
        return await delegate.run(session: downloadSession, request: request)
    }

    private static func makeAttachment(from data: Data, id: String, mimeType: String?) -> UNNotificationAttachment? {
        guard let localURL = writeTempFile(data, id: id, mimeType: mimeType) else { return nil }
        do {
            return try UNNotificationAttachment(identifier: id, url: localURL)
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            return nil
        }
    }

    private static func writeTempFile(_ data: Data, id: String, mimeType: String?) -> URL? {
        let ext = imageFileExtension(for: data, mimeType: mimeType)
        let safeStem = String(PushSharedStore.sanitizedImageFilename(for: id).dropLast(4))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeStem).\(ext)")
        guard (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    private static func imageFileExtension(for data: Data, mimeType: String?) -> String {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let type = CGImageSourceGetType(source) as String? {
            if let ext = fileExtension(forUTI: type) {
                return ext
            }
        }
        if let mimeType = mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if let ext = fileExtension(forMimeType: mimeType) {
                return ext
            }
            if let utType = UTType(mimeType: mimeType),
               let ext = fileExtension(forUTI: utType.identifier) ?? utType.preferredFilenameExtension {
                return ext
            }
        }
        return "jpg"
    }

    private static func fileExtension(forUTI uti: String) -> String? {
        switch uti {
        case UTType.jpeg.identifier: return "jpg"
        case UTType.png.identifier: return "png"
        case UTType.webP.identifier: return "webp"
        case UTType.heic.identifier, UTType.heif.identifier: return "heic"
        case UTType.gif.identifier: return "gif"
        default: return UTType(uti)?.preferredFilenameExtension
        }
    }

    private static func fileExtension(forMimeType mimeType: String) -> String? {
        switch mimeType {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/heic", "image/heif": return "heic"
        case "image/gif": return "gif"
        default: return nil
        }
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
    private static func updateLiveActivity(matching message: NtfyPushMessage) async {
        // Per Apple's guidance ("make it easy for people to turn them off in your app"), Settings
        // exposes this toggle. Turning it off here just stops this push-driven path from touching
        // activities further — `PrintLiveActivityManager.sync()` (the main app, on its next
        // refresh) is what actually ends any that are already running.
        guard PushSharedStore.liveActivitiesEnabled else { return }
        // With a relay configured, the relay is the activity's single content writer — the same
        // rule `PrintLiveActivityManager.sync` follows for the app. This path used to keep writing
        // anyway, from values it parses out of alert text (including Bambuddy's raw remaining
        // time, which the relay deliberately filters), so whichever of the two wrote last won and
        // the card flickered between their versions. The relay already pushes its own camera
        // frame and its own end event.
        guard !PushSharedStore.relayConfigured else { return }
        let text = (message.title ?? "") + " " + (message.message ?? "")
        let terminalLabel = terminalStateLabel(forTitle: message.title ?? "")
        let progress = progressFraction(forTitle: message.title ?? "")
        let remainingMinutes = remainingMinutes(fromMessage: message.message ?? "")

        let allActivities = Activity<PrintActivityAttributes>.activities
        NSELog.push.debug("NSE update terminalLabel=\(terminalLabel ?? "nil", privacy: .private) allActivities=\(allActivities.map { "id=\($0.id) printerID=\($0.attributes.printerID) state=\($0.activityState)" }.description, privacy: .private)")

        // Only `.active` activities count as a match — an already-ended one still lingers in
        // `.activities` through its dismissal window (up to 30 minutes), and without this a new
        // print starting on the same printer within that window would find the old, dismissing
        // activity, update it instead of the relay's fresh one, and never show a new card at all.
        let active = allActivities.filter { $0.activityState == .active }
        let matchedIDs = matchingPrinterIDs(in: text, candidates: active.map(\.attributes.printerID))
        for activity in active {
            guard matchedIDs.contains(activity.attributes.printerID) else {
                NSELog.push.debug("NSE no match: printerID=\(activity.attributes.printerID, privacy: .private) not named in this message")
                continue
            }
            NSELog.push.debug("NSE matched activity id=\(activity.id, privacy: .private) printerID=\(activity.attributes.printerID, privacy: .private)")
            var state = activity.content.state

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
                NSELog.push.debug("NSE ended activity id=\(activity.id, privacy: .private) resultingState=\(String(describing: activity.activityState), privacy: .private)")
            } else if let progress {
                // Bambuddy's progress titles carry the real percentage and remaining time (e.g.
                // "Print 70% Complete" / "...Remaining: 4m") — previously ignored entirely, which
                // left the Live Activity frozen at whatever value it started with (0% from the
                // relay's push-to-start, since it has no telemetry access) until the app was next
                // opened and did its own foreground refresh against Bambuddy's real API. Parsing
                // these directly out of the push text closes that gap without needing the
                // extension to make any of its own network calls.
                state.progress = progress
                // Same plausibility rule as the app and relay (`RemainingTimeTrust`): Bambuddy's
                // near-zero placeholder must not become a countdown to "now". An untrusted value
                // leaves the previous estimate alone rather than clearing it.
                if let remainingMinutes, RemainingTimeTrust.isTrustworthy(remainingMinutes: Double(remainingMinutes), progress: progress) {
                    state.estimatedEndAt = Date().addingTimeInterval(TimeInterval(remainingMinutes * 60))
                }
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    /// Which of `candidates` (normalized printer ids) the message text actually names.
    ///
    /// Bambuddy's messages carry no printer id, only the name somewhere in the text — sometimes
    /// the display name ("Vic H2C"), sometimes the slug ("vic-h2c"). Matching used to test whether
    /// the whole normalized text *contained* an id as a substring, so a printer "P1S" also matched
    /// every message about "P1S 2" or "P1S Combo" — and "Print Completed" on one ended the other's
    /// Live Activity. Now an id must equal a run of whole consecutive words (normalized the same
    /// way), and when two candidates both match, one that is merely part of the other's longer
    /// name ("p1s" inside "p1s2") is dropped: the message is about the longer-named printer.
    static func matchingPrinterIDs(in text: String, candidates: [String]) -> Set<String> {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        var runs: Set<String> = []
        for start in words.indices {
            var run = ""
            for end in start..<min(words.count, start + 6) {
                run += words[end]
                runs.insert(run)
            }
        }
        let matched = Set(candidates.filter { runs.contains($0) })
        return matched.filter { id in !matched.contains { $0 != id && $0.contains(id) } }
    }

    /// Whether a title announces the print itself ending, and how.
    ///
    /// This used to be a bare substring search for "complete"/"fail"/"cancel"/"stop" in *any*
    /// title, which kept ending Live Activities mid-print: progress milestones ("Print 50%
    /// Complete"), "First Layer Complete", and any other alert that happened to contain one of
    /// those words (an AI "failure detected" warning, a drying cycle "complete", …). Now the title
    /// must be about the print ("print"/"printing" as a word), must not be a percentage milestone
    /// or a layer milestone, and must use one of the actual end-state words as a whole word.
    static func terminalStateLabel(forTitle title: String) -> String? {
        guard progressFraction(forTitle: title) == nil else { return nil }
        let words = Set(title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        guard words.contains("print") || words.contains("printing"), !words.contains("layer") else { return nil }
        if !words.isDisjoint(with: ["complete", "completed", "finished"]) { return "Complete" }
        if words.contains("failed") { return "Failed" }
        if !words.isDisjoint(with: ["cancelled", "canceled"]) { return "Cancelled" }
        if words.contains("stopped") { return "Stopped" }
        return nil
    }

    /// Bambuddy's progress titles are consistently "Print {N}% Complete" — pulls the first
    /// integer immediately before a "%" and normalizes it to a 0...1 fraction for `ContentState`.
    static func progressFraction(forTitle title: String) -> Double? {
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

private final class ImageDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var continuation: CheckedContinuation<(data: Data, mimeType: String?)?, Never>?
        var task: URLSessionDataTask?
        var httpResponse: HTTPURLResponse?
        var buffer = Data()
        var exceededLimit = false
        var cancelled = false
    }

    private let maxBytes: Int
    private let allowedStatusCodes: Range<Int>
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(maxBytes: Int, allowedStatusCodes: Range<Int>) {
        self.maxBytes = maxBytes
        self.allowedStatusCodes = allowedStatusCodes
    }

    func run(session: URLSession, request: URLRequest) async -> (data: Data, mimeType: String?)? {
        guard !Task.isCancelled else { return nil }
        let task = session.dataTask(with: request)
        task.delegate = self

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResumeNil = state.withLock { state -> Bool in
                    if state.cancelled {
                        return true
                    }
                    state.continuation = continuation
                    state.task = task
                    return false
                }
                if shouldResumeNil {
                    continuation.resume(returning: nil)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            let taskToCancel = state.withLock { state -> URLSessionDataTask? in
                state.cancelled = true
                return state.task
            }
            taskToCancel?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              allowedStatusCodes.contains(http.statusCode),
              response.expectedContentLength <= Int64(maxBytes)
        else {
            state.withLock { state in
                state.exceededLimit = response.expectedContentLength > Int64(maxBytes)
            }
            completionHandler(.cancel)
            return
        }
        state.withLock { state in
            state.httpResponse = http
            if response.expectedContentLength > 0 {
                state.buffer.reserveCapacity(Int(response.expectedContentLength))
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let shouldCancel = state.withLock { state -> Bool in
            if state.exceededLimit || state.cancelled || state.buffer.count + data.count > maxBytes {
                state.exceededLimit = true
                state.buffer.removeAll(keepingCapacity: false)
                return true
            }
            state.buffer.append(data)
            return false
        }
        if shouldCancel {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, result) = state.withLock { state -> (CheckedContinuation<(data: Data, mimeType: String?)?, Never>?, (data: Data, mimeType: String?)?) in
            let continuation = state.continuation
            state.continuation = nil
            state.task = nil
            guard error == nil,
                  !state.exceededLimit,
                  !state.cancelled,
                  let http = state.httpResponse,
                  state.buffer.count <= maxBytes
            else {
                state.buffer.removeAll(keepingCapacity: false)
                return (continuation, nil)
            }
            let data = state.buffer
            state.buffer.removeAll(keepingCapacity: false)
            return (continuation, (data: data, mimeType: http.mimeType))
        }
        continuation?.resume(returning: result)
    }
}
