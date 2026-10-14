import Foundation
import Testing
@testable import JarvisCore

@Suite("Live spoken-step attempt matching")
struct LiveE2EAttemptMatchTests {
    @Test("a quiet check without this step's speech cannot advance the step")
    func unrelatedQuietCheck() {
        let match = LiveE2EAttemptMatch.speech(speaker: .them, transcriptBoundary: 2)
        #expect(!match.matches(started(reason: .silence(secondsQuiet: 45), boundary: 2, speakers: [])))
        #expect(!match.matches(started(reason: .silence(secondsQuiet: 45), boundary: 1, speakers: [.them])))
        #expect(!match.matches(started(reason: .silence(secondsQuiet: 45), boundary: 2, speakers: [.me])))
    }

    @Test("an unrelated quiet check is skipped before selecting the spoken attempt")
    func selectSpeechAfterQuietCheck() {
        let match = LiveE2EAttemptMatch.speech(speaker: .them, transcriptBoundary: 2)
        let attempts = [
            started(id: 1, reason: .silence(secondsQuiet: 45), boundary: 2, speakers: []),
            started(id: 2, reason: .turnEnd, boundary: 2, speakers: [.them]),
        ]
        #expect(attempts.first(where: match.matches)?.attemptID == 2)
    }

    @Test("a quiet check carrying finalized speech matches before its batched turn end")
    func quietCheckWithSpeech() {
        let match = LiveE2EAttemptMatch.speech(speaker: .them, transcriptBoundary: 2)
        #expect(match.matches(started(reason: .silence(secondsQuiet: 45), boundary: 2, speakers: [.them])))
    }

    @Test("retained old lines cannot substitute for new speech from the expected speaker")
    func mixedTranscriptBoundaries() {
        let match = LiveE2EAttemptMatch.speech(speaker: .them, transcriptBoundary: 3)
        #expect(!match.matches(started(reason: .turnEnd, boundary: 2, speakers: [.them, .me])))
        #expect(match.matches(started(reason: .turnEnd, boundary: 2, speakers: [.me, .them])))
    }

    @Test("early playback uses its original boundary even after that speech finalizes")
    func speechDuringPreviousAttempt() {
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .them, text: "previous step", at: 0))
        let earlyBoundary = transcript.count
        let match = LiveE2EAttemptMatch.speech(speaker: .them, transcriptBoundary: earlyBoundary)
        transcript.append(.init(speaker: .them, text: "early playback", at: 1))
        let attempt = started(reason: .turnEnd, boundary: earlyBoundary, speakers: [.them])

        #expect(match.matches(attempt))
        #expect(!LiveE2EAttemptMatch.speech(
            speaker: .them, transcriptBoundary: transcript.count).matches(attempt))
    }

    @Test(arguments: [CoachingShortcut.hint, .explainMore, .showCode])
    func shortcutsStillRequireTheirOwnReason(shortcut: CoachingShortcut) throws {
        let reason = try #require(shortcut.triggerReason)
        let manual = started(reason: reason, boundary: 2, speakers: [.them])
        #expect(LiveE2EAttemptMatch.shortcut(shortcut).matches(manual))
        #expect(!LiveE2EAttemptMatch.speech(speaker: .them, transcriptBoundary: 2).matches(manual))
        #expect(!LiveE2EAttemptMatch.shortcut(shortcut).matches(
            started(reason: .silence(secondsQuiet: 45), boundary: 2, speakers: [.them])))
    }

    private func started(
        id: Int = 1, reason: TriggerReason, boundary: Int, speakers: [Speaker]
    ) -> CoachingAttemptAuditEvent.Started {
        .init(attemptID: id, wake: .trigger, reason: reason,
              target: BrainTarget(provider: .codexSubscription, modelID: "test"),
              transcriptStartIndex: boundary,
              transcriptLines: speakers.map { .init(speaker: $0, text: "fixture speech", at: 1) },
              classifications: speakers.map { _ in .substantive },
              brainFacingTranscriptIndices: Set(boundary..<(boundary + speakers.count)),
              date: Date(timeIntervalSince1970: 1))
    }
}
