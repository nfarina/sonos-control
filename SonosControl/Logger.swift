import Foundation
import AppKit

class Logger {
    static let shared = Logger()

    private let logFileURL: URL
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.nfarina.SonosControl.logger")

    enum LogLevel: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SonosControl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.logFileURL = dir.appendingPathComponent("SonosControl.log")

        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        log("SonosControl launched", level: .info)
    }

    func log(_ message: String, level: LogLevel = .info) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
        print("\(level.rawValue): \(message)")

        queue.async { [logFileURL] in
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logFileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: logFileURL) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: logFileURL)
                }
            }
        }
    }

    func openLogFile() {
        NSWorkspace.shared.open(logFileURL)
    }

    func getLogFileURL() -> URL { logFileURL }
}

func logInfo(_ message: String) { Logger.shared.log(message, level: .info) }
func logWarning(_ message: String) { Logger.shared.log(message, level: .warning) }
func logError(_ message: String) { Logger.shared.log(message, level: .error) }
func logDebug(_ message: String) { Logger.shared.log(message, level: .debug) }
