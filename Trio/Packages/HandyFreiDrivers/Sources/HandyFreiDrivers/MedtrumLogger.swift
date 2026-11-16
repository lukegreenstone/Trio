import Foundation
import OSLog

/// Same call shape as MedtrumKit's logger, without the iOS pump-delegate sink.
final class MedtrumLogger {
    private let logger: Logger

    init(category: String) {
        logger = Logger(subsystem: "org.nightscout.HandyFreiDrivers", category: category)
    }

    func debug(_ msg: String, file: String = #file, _ function: String = #function, _ line: Int = #line) {
        logger.debug("\(msg, privacy: .public)")
    }

    func info(_ msg: String, file: String = #file, _ function: String = #function, _ line: Int = #line) {
        logger.info("\(msg, privacy: .public)")
    }

    func warning(_ msg: String, file: String = #file, _ function: String = #function, _ line: Int = #line) {
        logger.warning("\(msg, privacy: .public)")
    }

    func error(_ msg: String, file: String = #file, _ function: String = #function, _ line: Int = #line) {
        logger.error("\(msg, privacy: .public)")
    }
}
