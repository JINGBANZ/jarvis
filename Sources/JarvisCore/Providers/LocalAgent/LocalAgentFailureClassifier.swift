import Foundation

/// Failures from the local CLI adapters (Claude Code, Codex) arrive as NSErrors whose domain names
/// the adapter and whose code is the exit status, `NSURLErrorTimedOut`, or an errno. This is the
/// one place that reads them. Nothing here proves permanence: a CLI that exits non-zero once may
/// succeed on the next turn, and the stderr tail now reaches Activity through the message, so a
/// person sees "Not logged in" without the classifier guessing at substrings.
public enum LocalAgentFailureClassifier {
    public static let runtimeProcessDomain = "AgentRuntimeProcess"
    public static let processRunnerDomain = "AgentCLIProcessRunner"
    public static let clientDomain = "CLIBrainClient"
    public static let claudeCodeDomain = "ClaudeCodeRuntime"
    public static let codexAppServerDomain = "CodexAppServerRuntime"
    public static let codexExecDomain = "CodexExecRuntime"

    private static let adapterDomains: Set<String> = [
        runtimeProcessDomain, processRunnerDomain, clientDomain,
        claudeCodeDomain, codexAppServerDomain, codexExecDomain,
    ]

    public static func classify(error: any Error, provider: BrainProvider) -> ProviderFailure {
        if let failure = error as? ProviderFailure { return failure }
        let nsError = error as NSError
        let source = ProviderFailure.Source.brain(provider)
        if nsError.code == NSURLErrorTimedOut, adapterDomains.contains(nsError.domain) {
            return ProviderFailure(
                source: source, stage: .process, category: .timeout, disposition: .temporary,
                identity: .init(transportDomain: nsError.domain),
                message: nsError.localizedDescription)
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return ProviderFailure(
                source: source, stage: .process, category: .unavailable, disposition: .temporary,
                identity: .init(transportDomain: nsError.domain, transportCode: nsError.code),
                message: nsError.localizedDescription)
        }
        if nsError.domain == runtimeProcessDomain, nsError.code >= 0 {
            return ProviderFailure(
                source: source, stage: .process, category: .unknown, disposition: .temporary,
                identity: .init(transportDomain: nsError.domain, exitStatus: Int32(clamping: nsError.code)),
                message: nsError.localizedDescription)
        }
        return ProviderFailure(unclassified: error, source: source, stage: .process)
    }
}
