import Foundation

enum LaunchProbe {
    private static let queue = DispatchQueue(label: "local.yxp.grammarless.launchprobe")

    static var enabled: Bool {
        let environment = ProcessInfo.processInfo.environment
#if DEBUG
        if environment["GRAMMARLESS_STARTUP_PROBE"] == "0" {
            return false
        }
        if environment["GRAMMARLESS_STARTUP_PROBE"] == "1" {
            return true
        }
        if environment["GRAMMARLESS_DEBUG_LOG"] == "0" {
            return false
        }
        return true
#else
        return environment["GRAMMARLESS_DEBUG_LOG"] == "1" ||
        environment["GRAMMARLESS_STARTUP_PROBE"] == "1"
#endif
    }

    static var logPath: String {
        if let custom = ProcessInfo.processInfo.environment["GRAMMARLESS_STARTUP_LOG_PATH"], !custom.isEmpty {
            return custom
        }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("grammarless-launch-probe.log")
    }

    static func startSession(note: String) {
        guard enabled else { return }
        queue.sync {
            write("[\(timestamp())] === launch session ===\n\(note)\n", reset: true)
        }
    }

    static func log(_ message: String) {
        guard enabled else { return }
        queue.async {
            let line = "[\(timestamp())] \(message)\n"
            write(line, reset: false)
            NSLog("GrammarlessProbe %@", message)
        }
    }

    private static func write(_ text: String, reset: Bool) {
        guard let data = text.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: logPath)

        if reset || !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }

        FileHandle.standardError.write(data)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
