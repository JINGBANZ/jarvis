import Foundation
import JarvisCore

/// What one `AgentCLIRun` produced: captured stdout/stderr and the exit code.
public struct AgentCLIOutput: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}
