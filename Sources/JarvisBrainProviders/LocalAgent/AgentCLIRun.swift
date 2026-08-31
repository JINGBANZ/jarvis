import Foundation
import JarvisCore

/// One fully-described CLI invocation — the runner contract `CLIBrainClient` speaks, injectable in
/// tests so no real process is spawned there. Executed by `AgentCLIProcessRunner`; its result is an
/// `AgentCLIOutput`.
public struct AgentCLIRun: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let stdin: String?
    public let workingDirectory: URL
    public let timeout: TimeInterval

    public init(executable: URL, arguments: [String], stdin: String?,
                workingDirectory: URL, timeout: TimeInterval) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }
}
