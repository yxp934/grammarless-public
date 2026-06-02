import Foundation

enum DebugLogger {
    private static let queue = DispatchQueue(label: "local.yxp.grammarless.debuglog")

    static var enabled: Bool {
        let environmentValue = ProcessInfo.processInfo.environment["GRAMMARLESS_DEBUG_LOG"]
#if DEBUG
        return environmentValue != "0"
#else
        return environmentValue == "1"
#endif
    }

    static var logPath: String {
        if let custom = ProcessInfo.processInfo.environment["GRAMMARLESS_DEBUG_LOG_PATH"], !custom.isEmpty {
            return custom
        }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("grammarless-debug.log")
    }

    static func startSession(note: String) {
        guard enabled else { return }
        queue.sync {
            let header = "\n=== Grammarless session \(timestamp()) ===\n\(note)\n"
            emitToStderr(header)
            write(header, reset: true)
        }
    }

    static func log(_ message: @autoclosure @escaping () -> String) {
        guard enabled else { return }
        queue.async {
            let line = "[\(timestamp())] \(message())\n"
            emitToStderr(line)
            write(line, reset: false)
        }
    }

    private static func write(_ text: String, reset: Bool) {
        let url = URL(fileURLWithPath: logPath)
        let data = Data(text.utf8)
        if reset {
            try? data.write(to: url, options: .atomic)
            return
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url, options: .atomic)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static func emitToStderr(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
