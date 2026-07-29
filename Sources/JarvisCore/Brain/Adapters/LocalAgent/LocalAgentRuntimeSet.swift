import Foundation

/// Provider runtimes needed by one configured local-agent target.
///
/// Codex can host independently configured coach and summarizer threads on one app-server. Claude
/// fixes its model and system prompt when a query starts, so those roles need separate runtimes.
public struct LocalAgentRuntimeSet: Sendable {
    public let coach: CLIBrainRuntime
    public let summarizer: CLIBrainRuntime

    public init(
        provider: BrainProvider,
        codexSupportedFeatures: Set<String> = [],
        sharedCoach: CLIBrainRuntime? = nil
    ) {
        precondition(provider.usesLocalCLI, "local-agent runtimes need a CLI provider")
        let coach = sharedCoach ?? CLIBrainRuntime(
            provider: provider,
            codexSupportedFeatures: codexSupportedFeatures)
        self.coach = coach
        self.summarizer = provider == .codexCLI
            ? coach
            : CLIBrainRuntime(
                provider: provider,
                codexSupportedFeatures: codexSupportedFeatures)
    }
}
