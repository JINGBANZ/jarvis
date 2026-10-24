import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct NativeProcessLauncher: ProcessLaunching {
    public init() {}

    public func launch(_ process: Process, onLaunch: () -> Void) throws {
        do {
            try process.run()
        } catch {
            if process.processIdentifier > 0 {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            throw error
        }
        onLaunch()
    }
}
