import UserNotifications

/// Bambuddy's self-hosted ntfy server relays through the user's shared Firebase project as a
/// data-only push (no `aps.alert`), so iOS won't display anything unless something here builds
/// the notification content. Ported from the user's own ntfy app
/// (`ntfy-ios/ntfyNSE/NotificationService.swift`), trimmed to what Bambuddy's alerts actually
/// use: title/body/priority. Markdown stripping, attachments, and custom actions are dropped —
/// Bambuddy's notifications are plain text.
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
                handleMessage(message, content: content)
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

    private func handleMessage(_ message: NtfyPushMessage, content: UNMutableNotificationContent) {
        apply(message, to: content)
        deliver(content)
    }

    private func handlePollRequest(_ message: NtfyPushMessage, content: UNMutableNotificationContent) async {
        guard let config = PushSharedStore.loadNtfyConfig(),
              let polled = await NtfyPoller.poll(baseUrl: config.server, topic: message.topic, messageID: message.pollID ?? message.id, authToken: config.authToken)
        else {
            deliver(content)
            return
        }
        apply(polled, to: content)
        deliver(content)
    }

    private func apply(_ message: NtfyPushMessage, to content: UNMutableNotificationContent) {
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

        PushSharedStore.appendHistory(.init(
            id: message.id,
            title: content.title,
            body: content.body,
            receivedAt: Date()
        ))
    }
}
