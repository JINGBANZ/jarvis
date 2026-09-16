import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif

/// A shell script standing in for the helper, written owner-only into `directory`.
func proxyStubExecutable(in directory: URL, named name: String = "helper", script: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    guard FileManager.default.createFile(
        atPath: url.path, contents: Data("#!/bin/sh\n\(script)\n".utf8),
        attributes: [.posixPermissions: 0o700])
    else { throw CocoaError(.fileWriteUnknown) }
    return url
}

/// Polls until `condition` holds or `timeout` passes; the helper runs on its own schedule.
func eventually(
    timeout: Duration = .seconds(20), _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Whether a process with this id still exists.
func processExists(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}
