import Foundation
import JarvisCore

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
