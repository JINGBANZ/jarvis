import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif

/// Scripts wait with `idle` or `wait_for <file>`, which end once the test process is gone: a run
/// that dies mid-test must not leave a stub looping forever.
func proxyStubExecutable(in directory: URL, named name: String = "helper", script: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    let prelude = """
        #!/bin/sh
        test_process=$PPID
        idle() { while kill -0 "$test_process" 2>/dev/null; do sleep 0.05; done; exit 0; }
        wait_for() { until [ -e "$1" ]; do kill -0 "$test_process" 2>/dev/null || exit 0; sleep 0.05; done; }
        """
    guard FileManager.default.createFile(
        atPath: url.path, contents: Data("\(prelude)\n\(script)\n".utf8),
        attributes: [.posixPermissions: 0o700])
    else { throw CocoaError(.fileWriteUnknown) }
    return url
}

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

func processExists(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}
