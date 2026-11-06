import UIKit

/// Stand-ins for what a Bambuddy server would send, for App Store screenshots taken from demo data
/// (`-NCScreenshotMode`, see `ScreenshotMode`): plate covers, chamber camera frames and print
/// thumbnails for the `MockData` jobs, a Notifications list with photos, a SpoolBuddy scan and a
/// held queue job. Nothing here comes from a real printer.
///
/// The images live in `NozzleCast/ScreenshotMocks/` (rendered in Blender) and are left out of
/// Release builds by `EXCLUDED_SOURCE_FILE_NAMES = "ScreenshotMock-*"`, where screenshot mode is
/// off anyway; every lookup then finds nothing.
enum ScreenshotMocks {
    nonisolated static var isActive: Bool { ScreenshotMode.isActive }

    /// The rendered model a job or print-history name stands for.
    nonisolated private static func modelKey(_ name: String?) -> String? {
        guard let name = name?.lowercased() else { return nil }
        let keys: [(String, String)] = [
            ("honeycomb", "honeycomb"), ("gridfinity", "gridfinity"), ("twist", "twistvase"),
            ("lamp", "lampshade"), ("headphone", "headphonestand"), ("phone", "phonestand"),
            ("cable", "cableclips"), ("calibration", "calcube"), ("planter", "planter"),
        ]
        return keys.first { name.contains($0.0) }?.1
    }

    nonisolated private static func resource(_ name: String, _ ext: String) -> Data? {
        guard isActive, let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// A job's plate render, transparent like Bambuddy's.
    nonisolated static func coverData(job: String?) -> Data? {
        modelKey(job).flatMap { resource("ScreenshotMock-cover-\($0)", "png") }
    }

    /// The job's cover sized to a `pixelSize` tile, the model fitted to its height on a
    /// transparent canvas — what a relay's composed cover does for a real one, so a wide tile
    /// doesn't zoom into a square render.
    static func fittedCover(job: String?, pixelSize: CGSize) -> UIImage? {
        guard pixelSize.width > 0, pixelSize.height > 0,
              let data = coverData(job: job), let image = UIImage(data: data) else { return nil }
        let side = min(pixelSize.width, pixelSize.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in
            image.draw(in: CGRect(x: (pixelSize.width - side) / 2, y: (pixelSize.height - side) / 2, width: side, height: side))
        }
    }

    /// A chamber camera frame of the job part-way through.
    nonisolated static func cameraData(job: String?) -> Data? {
        modelKey(job).flatMap { resource("ScreenshotMock-camera-\($0)", "jpg") }
    }

    // MARK: Notifications

    static func notificationHistory(now: Date = Date()) -> [PushSharedStore.HistoryEntry] {
        func entry(_ id: String, _ title: String, _ body: String, minutesAgo: Double, read: Bool = true) -> PushSharedStore.HistoryEntry {
            PushSharedStore.HistoryEntry(id: id, title: title, body: body, receivedAt: now.addingTimeInterval(-minutesAgo * 60), isRead: read)
        }
        return [
            entry("mock-alert-paused", "Office P1S paused", "Vase_Mode_Twist paused at 31%: filament runout on AMS slot 3.", minutesAgo: 24, read: false),
            entry("mock-alert-started", "Workshop X1C started printing", "Gridfinity_Bin_2x3, about 2h 20m.", minutesAgo: 38),
            entry("mock-alert-finished", "Office P1S finished", "Phone_Stand finished in 1h 35m.", minutesAgo: 90),
            entry("mock-alert-mqtt", "Garage A1", "MQTT Command verification failed", minutesAgo: 185),
            entry("mock-alert-failed", "Garage A1 print failed", "Spaghetti detected on Vase_Mode_Lamp_Shade at 42%.", minutesAgo: 1200),
        ]
    }

    nonisolated static func notificationImage(id: String) -> Data? {
        let job: String? = switch id {
        case "mock-alert-paused": "twist"
        case "mock-alert-started": "gridfinity"
        case "mock-alert-finished": "phone"
        case "mock-alert-failed": "lamp"
        default: nil
        }
        return cameraData(job: job)
    }

    // MARK: SpoolBuddy

    /// A SpoolBuddy that's online, with a new Bambu spool on its scale whose tag no spool has.
    static let spoolBuddyEvents: [SpoolBuddyEvent] = [
        .online(deviceID: "mock-spoolbuddy", hostname: "spoolbuddy"),
        .unknownTag(
            deviceID: "mock-spoolbuddy", tagUID: "04A1B2C3D4E5F6", trayUUID: "8E2C41D07A5B4F39A1C6D2E8F0B7A913", tagType: "bambu",
            tagData: SpoolBuddyTagDataDTO(
                material: "PLA", subtype: "Matte", colorName: "Mandarin Orange", rgba: "F99963FF", brand: "Bambu Lab",
                labelWeight: 1000, nozzleTempMin: 190, nozzleTempMax: 230, variantId: "A01-A2", diameter: 1.75,
                dryingTemp: 55, dryingTime: 8
            )
        ),
        .weight(deviceID: "mock-spoolbuddy", grams: 1246, stable: true),
    ]

    // MARK: Queue

    /// What Bambuddy 1.3.0 answers when a job's filament runs short.
    static let filamentHold = QueueStartFilamentHold(
        body: #"{"detail":{"code":"insufficient_filament","deficit":[{"slot_id":1,"ams_id":0,"tray_id":0,"filament_type":"PLA","required_grams":142,"remaining_grams":58}]}}"#
    )
}
