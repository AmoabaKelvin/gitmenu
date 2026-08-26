import Foundation
import OSLog

/// Mirrors messages to a file because unified logging is unreliable to read from unsigned dev builds.
struct AppLog {
    private let os = Logger(subsystem: "com.kelvinamoaba.GitMenu", category: "app")
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GitMenu")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()
    private let fmt = ISO8601DateFormatter()

    func info(_ m: String) { os.info("\(m, privacy: .public)"); write("I", m) }
    func error(_ m: String) { os.error("\(m, privacy: .public)"); write("E", m) }

    private func write(_ level: String, _ m: String) {
        let line = "\(fmt.string(from: Date())) \(level) \(m)\n"
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

let logger = AppLog()
