import Foundation
import Testing
@testable import JarvisCore

@Suite struct LanguageRestrictionTests {
    @Test func automaticHintsAreLimitedToSupportedLanguages() throws {
        let payload = RealtimeSession.sessionUpdate(model: .gptLiveTranscribe)
        let session = try #require(payload["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(transcription["languages"] as? [String] == ["en", "zh-cn"])
    }

    @Test func selectionAndLocaleMatching() {
        let english = ConversationLanguagePolicy(expectedLanguages: [.english])
        #expect(english.allows(languageCode: "en-US"))
        #expect(!english.allows(languageCode: "ru"))
        #expect(!english.allows(languageCode: "zh-cn"))
        #expect(!english.allows(detectedLanguageCodes: ["en", "ru"]))
        #expect(english.allows(detectedLanguageCodes: nil))
        #expect(english.allows(detectedLanguageCodes: []))
        let automatic = ConversationLanguagePolicy()
        #expect(automatic.allows(languageCode: "zh-Hant"))
        #expect(automatic.allows(languageCode: "en_GB"))
        #expect(!automatic.allows(languageCode: "fr"))
        let mandarin = ConversationLanguagePolicy(expectedLanguages: [.mandarinChinese])
        #expect(mandarin.allows(languageCode: "zh-TW"))
        #expect(!mandarin.allows(languageCode: "en"))
        let apple = ConversationLanguagePolicy(localeIdentifier: "fr_FR")
        #expect(apple.allows(languageCode: "fr-CA"))
        #expect(!apple.allows(languageCode: "en"))
    }

    @Test func rejectedFinalSettlesWithoutResurrectingStreamedText() throws {
        let ledger = RealtimeTranscriptionLedger()
        ledger.recordSpeechStarted(itemID: "music", audioStartMilliseconds: 0, timelineOrigin: 0)
        ledger.recordSpeechStopped(itemID: "music", audioEndMilliseconds: 2_000)
        ledger.recordDelta(itemID: "music", delta: "apparently English partial")
        let final = try #require(ledger.recordCompleted(
            itemID: "music", transcript: "используемая тема", speaker: .me,
            languageAllowed: false))
        #expect(final.text == nil)
        #expect(!final.recoveredFromDeltas)
        #expect(!ledger.hasPendingItems)
        #expect(ledger.safeReplayDiscardTime == 2)
        #expect(ledger.recordFailed(itemID: "music", speaker: .me) == nil)

        let interrupted = RealtimeTranscriptionLedger()
        interrupted.recordDelta(itemID: "old", delta: "apparently English partial")
        var recovery = RealtimeReconnectTranscriptionRecovery()
        recovery.begin(interruptedItems: interrupted.resolveAllInterruptedItems(speaker: .me),
                       duplicateRiskItemCount: 0, replayAvailable: true)
        #expect(recovery.markReplacementReady().isEmpty)
        #expect(recovery.resolveReplacement(hasUsableText: false, languageRejected: true)
            == .appendReplacement)
        #expect(!recovery.blocksCoaching)
        #expect(recovery.timeout().isEmpty)
    }

    @Test(arguments: [Speaker.me, .them])
    func rejectedSpeechNeverReachesTranscriptOrActivity(speaker: Speaker) {
        let transcript = RollingTranscript()
        let coordinator = TranscriptionCoachingCoordinator(
            speaker: speaker, transcript: transcript, clock: ManualClock(now: 100),
            sessionStart: 100, transcriptBatchingWindow: 0, silenceTimeout: 10,
            silenceMaxInterval: 10, silenceEnabled: false,
            onTurnEnd: { _ in Issue.record("Rejected speech triggered coaching") },
            onSilence: { _ in }, onTranscriptionWorkChanged: { _ in },
            activity: NoLanguageActivity(), acceptsText: { _ in false })
        coordinator.start()
        coordinator.updateTranscriptionWork(true)
        #expect(!coordinator.recordFinalizedTranscript(
            "используемая тема", spokenAt: 1, source: "completed"))
        #expect(!coordinator.recordFinalizedTranscript(
            "используемая тема", spokenAt: 1, source: "reconnect fallback"))
        coordinator.updateTranscriptionWork(false)
        #expect(transcript.renderFrom(index: 0).text.isEmpty)
        coordinator.stop()
    }

    @Test func wrongLanguageReplyIsSuppressedWithoutRetryOrHistoryPollution() async {
        let wrong = "Если вы спрашиваете тему"
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "s1", lines: [wrong])],
                  rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                      argumentsJSON: "{\"lines\":[\"Если вы спрашиваете тему\"]}")]),
            .init(toolCalls: [.staySilent(callId: "s2")],
                  rawToolCalls: [RawToolCall(id: "s2", name: "stay_silent", argumentsJSON: "{}")])
        ])
        let target = BrainTarget(provider: .openAI,
                                 modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let transcript = RollingTranscript()
        let overlay = FakeOverlay()
        let policy = ConversationLanguagePolicy(expectedLanguages: [.english])
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [ConfiguredBrainTarget(target: target, brain: brain)]),
            screen: FakeScreen(), overlay: overlay, clock: ManualClock(now: 100),
            activity: NoLanguageActivity(), languagePolicy: policy,
            acceptsOutput: { $0 != wrong })
        transcript.append(.init(speaker: .me, text: "Please explain the undo design", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .suppressedLanguage)
        #expect(overlay.rendered.isEmpty)
        #expect(brain.calls.count == 1)
        #expect(brain.calls[0].contains {
            $0.role == .system && ($0.text ?? "").contains("Allowed languages: English.")
        })
        transcript.append(.init(speaker: .me, text: "Let me think about the stack", at: 2))
        _ = await driver.handleTrigger(.turnEnd)
        #expect(brain.calls.count == 2)
        #expect(!brain.calls[1].contains { ($0.text ?? "").contains(wrong) })
    }
}

private struct NoLanguageActivity: ActivityEventRecording {
    func record(_ event: ActivityEvent, at date: Date) {
        switch event {
        case .heard, .tip: Issue.record("Rejected language reached Activity")
        default: break
        }
    }
}
