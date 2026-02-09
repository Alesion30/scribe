import Foundation
import os

/// Lightweight logging utility for scribe CLI.
/// Verbose output goes to stderr so it doesn't interfere with stdout transcription output.
enum Log {
    /// Set to true when --verbose is passed.
    nonisolated(unsafe) static var verbose = false

    private static let logger = os.Logger(subsystem: "com.scribe.cli", category: "general")

    static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        let msg = message()
        logger.debug("\(msg, privacy: .public)")
        eprintln("[debug] \(msg)")
    }

    static func info(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        let msg = message()
        logger.info("\(msg, privacy: .public)")
        eprintln("[info] \(msg)")
    }

    static func warning(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.warning("\(msg, privacy: .public)")
        eprintln("[warn] \(msg)")
    }

    static func error(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.error("\(msg, privacy: .public)")
        eprintln("[error] \(msg)")
    }

    /// Print a user-facing status message to stderr (always shown, not just in verbose mode).
    static func status(_ message: String) {
        eprintln(message)
    }

    /// Print a progress indicator to stderr (overwrites current line).
    static func progress(_ message: String) {
        FileHandle.standardError.write(Data("\r\(message)".utf8))
    }
}

/// Print to stderr.
func eprintln(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
