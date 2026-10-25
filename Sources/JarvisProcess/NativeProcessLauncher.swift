import Foundation

public struct NativeProcessLauncher: ProcessLaunching {
    public init() {}

    public func launch(_ process: Process, onLaunch: () -> Void) throws {
        try process.run()
        onLaunch()
    }
}
