import os

nonisolated enum AppLog {
    private static let subsystem = "com.victormanuel.NozzleCast"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let push = Logger(subsystem: subsystem, category: "push")
    static let liveActivity = Logger(subsystem: subsystem, category: "liveActivity")
    static let storage = Logger(subsystem: subsystem, category: "storage")
}
