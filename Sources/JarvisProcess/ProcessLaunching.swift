import Foundation

public protocol ProcessLaunching: Sendable {
    /// Calls `onLaunch` synchronously after spawn. A known spawned child must exit before throwing.
    func launch(_ process: Process, onLaunch: () -> Void) throws
}

extension ProcessLaunching {
    public func launch(_ process: Process) throws {
        try launch(process, onLaunch: {})
    }
}
