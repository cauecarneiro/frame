import OSLog

enum Log {
    private static let subsystem = "com.cauecarneiro.frame"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let vision = Logger(subsystem: subsystem, category: "vision")
    static let render = Logger(subsystem: subsystem, category: "render")
    static let project = Logger(subsystem: subsystem, category: "project")
}
