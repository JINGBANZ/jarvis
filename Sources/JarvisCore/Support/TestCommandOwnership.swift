import Foundation

/// Explicit developer harness receipts for LaunchServices apps and their detached helpers.
public enum TestCommandOwnership {
    public static var environment: [String: String] {
        let source = ProcessInfo.processInfo.environment
        return source.filter { ["JARVIS_TEST_RUN_SOCKET", "JARVIS_TEST_RUN_TOKEN", "JARVIS_TEST_SUPERVISOR", "JARVIS_TEST_PYTHON"].contains($0.key) }
    }

    public static func registerApplication() throws {
        _ = try report(["register-app"])
    }

    public static func launchChild(_ child: Process) throws {
        guard ProcessInfo.processInfo.environment["JARVIS_TEST_RUN_SOCKET"] != nil else {
            try child.run()
            return
        }
        let receipt = try report(["prepare-child"])
        guard let launch = receipt["launch"] as? String else { throw CocoaError(.coderInvalidValue) }
        do {
            try child.run()
            _ = try report(["register-child", String(child.processIdentifier), launch])
        } catch {
            if child.isRunning { child.terminate() }
            throw error
        }
    }

    private static func report(_ arguments: [String]) throws -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JARVIS_TEST_RUN_SOCKET"] != nil else { return [:] }
        guard let python = environment["JARVIS_TEST_PYTHON"], let script = environment["JARVIS_TEST_SUPERVISOR"] else { throw CocoaError(.executableNotLoadable) }
        guard python.hasPrefix("/"), script.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: python) else { throw CocoaError(.executableNotLoadable) }
        let reporter = Process()
        reporter.executableURL = URL(fileURLWithPath: python)
        reporter.arguments = ["-I", script] + arguments
        let output = Pipe()
        reporter.standardOutput = output
        try reporter.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        reporter.waitUntilExit()
        guard reporter.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
        return data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
    }
}
