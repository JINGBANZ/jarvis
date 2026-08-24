import Foundation

/// Provider runtimes needed by one configured local-agent target.
///
/// The summarizer always gets a runtime of its own. Claude needs one because a query fixes its model
/// and system prompt when it starts. Codex needs one because its app-server admits a single
/// conversation at a time: sharing it let a background summary fail the next coaching attempt, and
/// three such failures exhaust the target. Codex's summarizer spawns a short-lived `codex exec` per
/// summary instead of holding a second app-server open for the whole session to do a few seconds of
/// work.
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
            ? CLIBrainRuntime(
                backend: CodexExecRuntime(supportedFeatures: codexSupportedFeatures))
            : CLIBrainRuntime(
                provider: provider,
                codexSupportedFeatures: codexSupportedFeatures)
    }
}
