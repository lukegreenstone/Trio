import Foundation
import os

/// Same call shape as LibreLoop's `llog` (LibreLoop/Common/LibreLoopFileLogger.swift).
/// The watch package does not write Loop's device log or a file log. Console gets the line.
func llog(_ message: String,
          file: String = #fileID,
          line: Int = #line,
          category: StaticString = "CGMManager") {
    let logger = Logger(subsystem: "org.nightscout.HandyFreiDrivers", category: String(describing: category))
    logger.info("[\(file, privacy: .public):\(line, privacy: .public)] \(message, privacy: .public)")
}
