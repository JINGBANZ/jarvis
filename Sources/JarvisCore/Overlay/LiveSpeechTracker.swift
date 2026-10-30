import Foundation

/// Each speaker's speech still in progress, for the transcript column. Interim text is dropped
/// once that speaker's work settles, so a stale hypothesis never outlives its final.
/// `@unchecked Sendable`: `lock` guards both dictionaries; transcription callbacks write from their
/// own queues while the column reads on the main thread.
public final class LiveSpeechTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingSince: [Speaker: TimeInterval?] = [:]
    private var interim: [Speaker: String] = [:]

    public init() {}

    public func update(_ state: TranscriptionWorkState, for speaker: Speaker) {
        lock.withLock {
            switch state {
            case .settled:
                pendingSince[speaker] = nil
                interim[speaker] = nil
            case .pending(let since):
                pendingSince[speaker] = .some(since)
            }
        }
    }

    public func updateInterim(_ text: String?, for speaker: Speaker) {
        lock.withLock { interim[speaker] = text }
    }

    public func snapshot() -> [Speaker: TranscriptPaneContent.LiveSpeech] {
        lock.withLock {
            var live: [Speaker: TranscriptPaneContent.LiveSpeech] = [:]
            for speaker in [Speaker.me, .them] {
                if let text = interim[speaker] {
                    live[speaker] = .interim(text)
                } else if let since = pendingSince[speaker] {
                    live[speaker] = .speaking(since: since)
                }
            }
            return live
        }
    }
}
