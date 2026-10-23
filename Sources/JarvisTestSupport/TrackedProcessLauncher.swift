#if DEBUG
import Darwin
import Foundation
import JarvisProcess

public struct TrackedProcessLauncher: ProcessLaunching {
    public init() {}

    public func launch(_ process: Process, onLaunch: () -> Void) throws {
        let receipt = try TestCommandOwnership.report(["prepare-child"])
        guard let launch = receipt["launch"] as? String else { throw CocoaError(.coderInvalidValue) }
        if let environment = process.environment {
            process.environment = environment.merging(TestCommandOwnership.environment) { _, ownership in ownership }
        }
        do {
            try NativeProcessLauncher().launch(process, onLaunch: onLaunch)
        } catch {
            if process.processIdentifier == 0, !process.isRunning, Self.isNoSpawnError(error) {
                _ = try TestCommandOwnership.report(["no-child", launch])
            }
            throw error
        }
        do {
            _ = try TestCommandOwnership.report(["register-child", String(process.processIdentifier), launch])
        } catch {
            // Callers may remove child-owned output when launch throws. Keep the pending receipt.
            Self.reap(process)
            throw error
        }
    }

    private static func reap(_ process: Process) {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private static func isNoSpawnError(_ error: Error) -> Bool {
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain {
            return [POSIXErrorCode.ENOENT, .EACCES, .ENOEXEC, .ENOTDIR].contains {
                Int($0.rawValue) == failure.code
            }
        }
        return failure.domain == NSCocoaErrorDomain && [
            CocoaError.Code.fileNoSuchFile, .fileReadNoSuchFile, .fileReadNoPermission,
            .executableNotLoadable,
        ].contains { $0.rawValue == failure.code }
    }
}
#endif
