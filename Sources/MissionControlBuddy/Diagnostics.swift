import Foundation

/// Appends diagnostic lines to ~/Library/Logs/MissionControlBuddy.log.
/// NSLog output from this accessory app does not reliably show up in the
/// unified log, and a plain file is easier for users to paste into an issue.
enum Diagnostics {
    static let fileURL: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return logs.appendingPathComponent("MissionControlBuddy.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        NSLog("%@", message)
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
