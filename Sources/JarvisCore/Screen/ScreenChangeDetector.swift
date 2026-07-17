import Foundation

/// Pure state machine for deciding when a polled screen capture represents a stable change.
///
/// The session monitor seeds a baseline from its first local poll. A changed fingerprint must then
/// be present in consecutive polls before it is reported, so a stream of intermediate typing states
/// coalesces into one stable change. Reporting does not advance the baseline: only `observe(_:)`,
/// called when CoachDriver accepts the snapshot, acknowledges that the coach actually saw it.
public struct ScreenChangeDetector: Sendable {
    public enum PollResult: Sendable, Equatable {
        case dormant
        case unchanged
        case waitingForStability
        case awaitingAcknowledgement
        case stableChange
    }

    private struct ContentHash: Sendable, Equatable {
        enum Source: Sendable, Equatable {
            case recognizedText
            case image
        }

        let source: Source
        let hash: UInt64
        let byteCount: Int
    }

    private enum VisualHash: Sendable, Equatable {
        case perceptual(UInt64)
        case exact(ContentHash)
    }

    private struct Fingerprint: Sendable, Equatable {
        let text: ContentHash?
        let visual: VisualHash
    }

    private let requiredStablePollCount: Int
    private var baseline: Fingerprint?
    private var candidate: Fingerprint?
    private var candidatePollCount = 0
    private var candidateWasReported = false

    public init(requiredStablePollCount: Int = 2) {
        precondition(requiredStablePollCount >= 1,
                     "A screen change needs at least one observation")
        self.requiredStablePollCount = requiredStablePollCount
    }

    public var isSeeded: Bool { baseline != nil }

    /// Seeds the first local observation without treating it as a change. Returns true only when it
    /// established the baseline; later calls leave current detector state untouched.
    @discardableResult
    public mutating func seedIfNeeded(_ snapshot: ScreenSnapshot) -> Bool {
        guard baseline == nil else { return false }
        observe(snapshot)
        return true
    }

    /// Replaces the baseline with a screenshot the coach actually consumed. Any pending candidate
    /// is obsolete because the coach is now up to date with this newer screen state.
    public mutating func observe(_ snapshot: ScreenSnapshot) {
        baseline = Self.fingerprint(for: snapshot)
        clearCandidate()
    }

    /// Evaluates one background poll. A stable change remains pending until `observe(_:)`
    /// acknowledges the snapshot that CoachDriver accepted.
    public mutating func poll(_ snapshot: ScreenSnapshot) -> PollResult {
        guard let baseline else { return .dormant }
        let fingerprint = Self.fingerprint(for: snapshot)

        guard !Self.matches(fingerprint, baseline) else {
            clearCandidate()
            return .unchanged
        }

        if candidate.map({ Self.matches($0, fingerprint) }) == true {
            candidatePollCount += 1
        } else {
            candidate = fingerprint
            candidatePollCount = 1
            candidateWasReported = false
        }

        guard candidatePollCount >= requiredStablePollCount else {
            return .waitingForStability
        }

        guard !candidateWasReported else { return .awaitingAcknowledgement }
        candidateWasReported = true
        return .stableChange
    }

    /// Returns to the dormant state, for example when a coaching session stops.
    public mutating func reset() {
        baseline = nil
        clearCandidate()
    }

    /// Allows a stable candidate to be emitted again after the consumer reports that delivery
    /// failed. It does not change the acknowledged baseline or the candidate's stability count.
    public mutating func retryUnacknowledgedChange() {
        candidateWasReported = false
    }

    private mutating func clearCandidate() {
        candidate = nil
        candidatePollCount = 0
        candidateWasReported = false
    }

    private static func fingerprint(for snapshot: ScreenSnapshot) -> Fingerprint {
        let text: ContentHash?
        if let recognizedText = snapshot.recognizedText {
            let normalized = recognizedText.precomposedStringWithCanonicalMapping
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            if !normalized.isEmpty {
                text = contentHash(normalized, source: .recognizedText)
            } else {
                text = nil
            }
        } else if let token = snapshot.changeFingerprint, !token.isEmpty {
            // Whole-display OCR is intentionally not sent with the snapshot; its content-free token
            // is still useful for local duplicate suppression.
            text = contentHash(token, source: .recognizedText)
        } else {
            text = nil
        }
        let visual = snapshot.visualFingerprint.map(VisualHash.perceptual)
            ?? .exact(contentHash(snapshot.imageBase64, source: .image))
        return Fingerprint(text: text, visual: visual)
    }

    private static func matches(_ lhs: Fingerprint, _ rhs: Fingerprint) -> Bool {
        // OCR can transiently fail, so the visual signal decides when only one side has text. When
        // both have OCR, require equality so small but semantically important code edits are kept.
        if let leftText = lhs.text, let rightText = rhs.text, leftText != rightText { return false }
        switch (lhs.visual, rhs.visual) {
        case (.perceptual(let left), .perceptual(let right)):
            return (left ^ right).nonzeroBitCount <= 8
        case (.exact(let left), .exact(let right)):
            return left == right
        case (.perceptual, .exact), (.exact, .perceptual):
            return false
        }
    }

    /// Makes a deterministic, content-free token from screen-derived text. The raw OCR remains only
    /// in the capture call; the monitor retains this hash + byte count for local duplicate detection.
    public static func privacyPreservingTextFingerprint(_ text: String) -> String? {
        let normalized = text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        let value = contentHash(normalized, source: .recognizedText)
        return "ocr:\(value.hash):\(value.byteCount)"
    }

    /// FNV-1a keeps the detector Foundation-only and avoids retaining duplicate screenshot/OCR
    /// strings. Including both the source and byte count makes accidental equivalence still less
    /// likely without persisting any screen-derived content.
    private static func contentHash(_ value: String,
                                    source: ContentHash.Source) -> ContentHash {
        var hash: UInt64 = 14_695_981_039_346_656_037
        var byteCount = 0
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
            byteCount += 1
        }
        return ContentHash(source: source, hash: hash, byteCount: byteCount)
    }
}
