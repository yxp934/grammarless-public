import AppKit
import Foundation

LaunchProbe.startSession(
    note: """
    pid=\(ProcessInfo.processInfo.processIdentifier)
    bundle=\(Bundle.main.bundleIdentifier ?? "unknown")
    argv=\(CommandLine.arguments.joined(separator: " "))
    debugLogEnv=\(ProcessInfo.processInfo.environment["GRAMMARLESS_DEBUG_LOG"] ?? "unset")
    debugLogEnabled=\(DebugLogger.enabled)
    debugLogPath=\(DebugLogger.logPath)
    startupProbeEnv=\(ProcessInfo.processInfo.environment["GRAMMARLESS_STARTUP_PROBE"] ?? "unset")
    startupProbeEnabled=\(LaunchProbe.enabled)
    startupProbePath=\(LaunchProbe.logPath)
    """
)

@MainActor
func runGrammarlessApp() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate

    LaunchProbe.log("main.swift assigned delegate=\(String(describing: application.delegate))")
    application.finishLaunching()
    LaunchProbe.log("main.swift finishLaunching completed")
    application.run()
    LaunchProbe.log("main.swift application.run returned")
}

MainActor.assumeIsolated {
    runGrammarlessApp()
}
