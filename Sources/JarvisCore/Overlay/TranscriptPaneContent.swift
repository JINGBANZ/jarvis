import Foundation

/// What the Overlay Box's transcript column shows. Display-only: interim text lives here and never
/// reaches the transcript, Activity, or a model request.
public struct TranscriptPaneContent: Sendable, Equatable {
    public enum RowState: Sendable, Equatable {
        /// A completed attempt has consumed the line: sent to the brain, or skipped as filler.
        case handled
        case unhandled
        case inProgress
    }

    public struct Row: Sendable, Equatable {
        public let speaker: Speaker
        public let text: String
        public let state: RowState

        public init(speaker: Speaker, text: String, state: RowState) {
            self.speaker = speaker
            self.text = text
            self.state = state
        }
    }

    public enum LiveSpeech: Sendable, Equatable {
        /// Session-relative start, or nil while the provider cannot tell.
        case speaking(since: TimeInterval?)
        case interim(String)
    }

    /// Bounds the column, not the transcript.
    public static let lineLimit = 200

    public let rows: [Row]

    public init(rows: [Row]) {
        self.rows = rows
    }

    /// `lines` are in insertion order and `lines[0]` sits at transcript index `firstIndex`, the
    /// same index space as the coach's committed boundary, `handledCount`. `now` is
    /// session-relative.
    public static func make(
        lines: [TranscriptLine],
        firstIndex: Int,
        handledCount: Int,
        live: [Speaker: LiveSpeech],
        now: TimeInterval
    ) -> TranscriptPaneContent {
        let indexed = lines.enumerated().map { (index: firstIndex + $0.offset, line: $0.element) }
        let finalized = ConversationChronology.ordered(indexed, occurredAt: \.line.at).map {
            Row(speaker: $0.line.speaker, text: $0.line.text,
                state: $0.index < handledCount ? .handled : .unhandled)
        }
        let inProgress = [Speaker.them, .me].compactMap { speaker in
            live[speaker].flatMap { liveRow(for: speaker, $0, now: now) }
        }
        return TranscriptPaneContent(rows: finalized + inProgress)
    }

    private static func liveRow(for speaker: Speaker, _ speech: LiveSpeech, now: TimeInterval) -> Row? {
        switch speech {
        case .interim(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Row(speaker: speaker, text: trimmed, state: .inProgress)
        case .speaking(let since):
            let text = since.map { "speaking… \(Int(max(0, now - $0)))s" } ?? "speaking…"
            return Row(speaker: speaker, text: text, state: .inProgress)
        }
    }
}
