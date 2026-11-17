import Foundation
import OSLog

enum AppLogger {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "TeraPlayer",
        category: "application"
    )

    static func debug(_ message: String) {
        #if DEBUG
        logger.debug("\(message, privacy: .private)")
        #endif
    }

    static func error(_ message: String) {
        #if DEBUG
        logger.error("\(message, privacy: .private)")
        #endif
    }
}
