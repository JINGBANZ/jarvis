import Foundation

/// What one `AgentCLIRun` produced: captured stdout/stderr and the exit code.
public struct AgentCLIOutput: Sendable {
    public enum Termination: Sendable, Equatable {
        case exited
        case completionSignal(AgentCLICompletionSignal.Reason)
    }

    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let termination: Termination

    public init(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        termination: Termination = .exited
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.termination = termination
    }
}
