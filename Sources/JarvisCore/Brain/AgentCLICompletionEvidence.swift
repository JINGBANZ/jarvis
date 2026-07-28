import Foundation

/// What the process runner must observe before an external completion signal may stop a CLI.
///
/// Some transports can prove only that result bytes were written. A structured CLI stream can add
/// the stronger client-side boundary: the matching tool result was decoded and emitted by the CLI.
public enum AgentCLICompletionEvidence: Sendable, Equatable {
    /// The signal itself is the strongest boundary available for this CLI.
    case signal

    /// Wait for a successful JSONL `tool_result` emitted for a preceding terminal `tool_use`.
    case stdoutJSONToolResult(
        toolNames: Set<String>,
        acceptedText: String
    )
}
