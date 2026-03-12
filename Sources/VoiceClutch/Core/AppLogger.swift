import Foundation
import OSLog

/// Lightweight logger that writes to Unified Logging and mirrors to stderr in debug builds.
public struct AppLogger: Sendable {
    nonisolated(unsafe) public static var defaultSubsystem: String = "dev.vm.voiceclutch"

    public enum Level: Int, Sendable {
        case debug = 0
        case info
        case notice
        case warning
        case error
        case fault
    }

    private let osLogger: Logger
    private let category: String

    public init(subsystem: String, category: String) {
        self.osLogger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    public init(category: String) {
        self.init(subsystem: AppLogger.defaultSubsystem, category: category)
    }

    public func debug(_ message: String) {
        log(.debug, message)
    }

    public func info(_ message: String) {
        log(.info, message)
    }

    public func notice(_ message: String) {
        log(.notice, message)
    }

    public func warning(_ message: String) {
        log(.warning, message)
    }

    public func error(_ message: String) {
        log(.error, message)
    }

    public func fault(_ message: String) {
        log(.fault, message)
    }

    private func log(_ level: Level, _ message: String) {
        #if DEBUG
        logToConsole(level, message)
        #else
        switch level {
        case .debug:
            osLogger.debug("\(message)")
        case .info:
            osLogger.info("\(message)")
        case .notice:
            osLogger.notice("\(message)")
        case .warning:
            osLogger.warning("\(message)")
            logToConsole(level, message)
        case .error:
            osLogger.error("\(message)")
            logToConsole(level, message)
        case .fault:
            osLogger.fault("\(message)")
            logToConsole(level, message)
        }
        #endif
    }

    private func logToConsole(_ level: Level, _ message: String) {
        let capturedLevel = level
        let capturedCategory = category
        let capturedMessage = message

        #if !DEBUG
        if level.rawValue >= Level.warning.rawValue {
            logToConsoleSynchronously(level: capturedLevel, category: capturedCategory, message: capturedMessage)
            return
        }
        #endif

        Task.detached(priority: .utility) { [capturedLevel, capturedCategory, capturedMessage] in
            await LogConsole.shared.write(level: capturedLevel, category: capturedCategory, message: capturedMessage)
        }
    }

    private func logToConsoleSynchronously(level: Level, category: String, message: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(label(for: level))] [\(category)] \(message)\n"

        do {
            try FileHandle.standardError.write(contentsOf: Data(line.utf8))
        } catch {
            print("Failed to write to stderr: \(error.localizedDescription)")
        }
    }

    private func label(for level: Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        }
    }
}

actor LogConsole {
    static let shared = LogConsole()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func write(level: AppLogger.Level, category: String, message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(label(for: level))] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        do {
            try FileHandle.standardError.write(contentsOf: data)
        } catch {
            print("Failed to write to standard error: \(error.localizedDescription)")
        }
    }

    private func label(for level: AppLogger.Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        }
    }
}
