import Foundation

public protocol ProcessLaunching: Sendable {
    /// Calls `onLaunch` synchronously after a successful spawn.
    func launch(_ process: Process, onLaunch: () -> Void) throws
}

extension ProcessLaunching {
    public func launch(_ process: Process) throws {
        try launch(process, onLaunch: {})
    }
}
