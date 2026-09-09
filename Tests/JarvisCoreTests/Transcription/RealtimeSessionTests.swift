import Foundation
import Testing
@testable import JarvisCore

@Suite struct RealtimeSessionTests {
    /// A completed-transcription wire event (the same JSON the socket delivers) yields its text —
    /// this is the parse the two speaker-tagged transcribers depend on.
    @Test func completedTranscriptParsesCompletedEvent() throws {
        let wire = "{\"type\":\"\(RealtimeSession.completedTranscriptionType)\",\"transcript\":\"two pointers\"}"
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any])
        #expect(RealtimeSession.completedTranscript(from: obj, speaker: .me) == "two pointers")
    }

    /// Non-completed events, empty text, and a missing transcript field all yield nil (no line gets
    /// appended / no speaker tagged for them).
    @Test func completedTranscriptIgnoresNonCompletedAndEmpty() {
        let type = RealtimeSession.completedTranscriptionType
        #expect(RealtimeSession.completedTranscript(from: ["type": "input_audio_buffer.speech_stopped"], speaker: .me) == nil)
        #expect(RealtimeSession.completedTranscript(from: ["type": type, "transcript": ""], speaker: .me) == nil)
        #expect(RealtimeSession.completedTranscript(from: ["type": type], speaker: .me) == nil)
        #expect(RealtimeSession.completedTranscript(from: [:], speaker: .me) == nil)
    }

    /// Layer 3 (text filter): the model hallucinates a lone "." (and other punctuation/whitespace) when
    /// server VAD fires on non-speech. No real utterance is punctuation-only, so these are dropped for
    /// BOTH speakers — otherwise each one logs a phantom `heard` line, resets the silence timer (me side),
    /// and fires a turn.
    @Test func completedTranscriptRejectsPunctuationAndWhitespaceOnly() {
        for speaker in [Speaker.me, .them] {
            for junk in [".", " . ", "…", ",", ". .", "?!", "  ", "\n", "-"] {
                #expect(RealtimeSession.meaningfulTranscript(junk, speaker: speaker) == nil,
                        "\(speaker) should drop \(junk.debugDescription)")
            }
        }
    }

    /// Layer 3 (denylist): gpt-4o-transcribe / Whisper emit stock caption-artifact phrases on silence
    /// ("Thank you.", "Thanks for watching"). On the ME side these are hallucinations and are dropped —
    /// every entry, plus a Capitalized + trailing-punctuation variant to exercise normalization.
    @Test func completedTranscriptRejectsEveryDenylistedPhraseOnMeSide() {
        for phrase in RealtimeSession.hallucinationDenylist {
            #expect(RealtimeSession.meaningfulTranscript(phrase, speaker: .me) == nil,
                    "me should drop \(phrase.debugDescription)")
            #expect(RealtimeSession.meaningfulTranscript(phrase.capitalized + ".", speaker: .me) == nil,
                    "me should drop normalized \(phrase.debugDescription)")
        }
    }

    /// The denylist is a ME-side artifact filter only. On the THEM (system-audio) side a bare
    /// "Thank you."/"Thanks" is a real conversational closer that must still fire a turn, so it is kept
    /// (trimmed). Punctuation/whitespace-only noise is still dropped for them.
    @Test func completedTranscriptKeepsDenylistedPhrasesOnThemSide() {
        #expect(RealtimeSession.meaningfulTranscript("Thank you.", speaker: .them) == "Thank you.")
        #expect(RealtimeSession.meaningfulTranscript("thanks", speaker: .them) == "thanks")
        #expect(RealtimeSession.meaningfulTranscript(".", speaker: .them) == nil)
    }

    /// "bye" was removed from the denylist: a lone sign-off is well-formed real speech even on the me
    /// side, and the punctuation filter already covers the lone-"." artifact.
    @Test func byeIsNotFiltered() {
        #expect(!RealtimeSession.hallucinationDenylist.contains("bye"))
        #expect(RealtimeSession.meaningfulTranscript("Bye.", speaker: .me) == "Bye.")
    }

    /// Real speech survives, and is returned trimmed of surrounding whitespace. A sentence that merely
    /// contains a denylisted phrase as a substring is NOT dropped.
    @Test func completedTranscriptKeepsAndTrimsRealSpeech() {
        #expect(RealtimeSession.meaningfulTranscript("  two pointers  ", speaker: .me) == "two pointers")
        #expect(RealtimeSession.meaningfulTranscript("thank you, let's use a hash map", speaker: .me)
                == "thank you, let's use a hash map")
        #expect(RealtimeSession.meaningfulTranscript("3", speaker: .me) == "3")  // a lone digit is real
    }

    /// The filtering must take effect through the PUBLIC entry point the app actually calls
    /// (`completedTranscript(from:speaker:)`), not only the internal helper — so a regression of the
    /// one-line delegation can't slip through green tests.
    @Test func completedTranscriptFiltersThroughPublicEntryPoint() {
        let type = RealtimeSession.completedTranscriptionType
        func event(_ t: String) -> [String: Any] { ["type": type, "transcript": t] }
        #expect(RealtimeSession.completedTranscript(from: event("."), speaker: .me) == nil)
        #expect(RealtimeSession.completedTranscript(from: event("."), speaker: .them) == nil)
        #expect(RealtimeSession.completedTranscript(from: event("Thank you."), speaker: .me) == nil)
        #expect(RealtimeSession.completedTranscript(from: event("Thank you."), speaker: .them) == "Thank you.")
        #expect(RealtimeSession.completedTranscript(from: event("  two pointers "), speaker: .me) == "two pointers")
    }

    /// The connect URL MUST select a transcription session via intent (not ?model=).
    @Test func connectURLUsesIntentTranscription() {
        let url = RealtimeSession.connectURL().absoluteString
        #expect(url == "wss://api.openai.com/v1/realtime?intent=transcription")
        #expect(!url.contains("model="))
    }

    @Test func sessionUpdateShape() throws {
        let payload = RealtimeSession.sessionUpdate(model: .gpt4oTranscribe)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["type"] as? String == "session.update")
        let session = obj["session"] as! [String: Any]
        #expect(session["type"] as? String == "transcription")
        let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
        #expect(((input["format"] as! [String: Any])["rate"] as? Int) == 24_000)
        let transcription = input["transcription"] as! [String: Any]
        #expect(transcription["model"] as? String == "gpt-4o-transcribe")
        #expect(transcription["language"] == nil)
        #expect(transcription["languages"] == nil)
        let td = input["turn_detection"] as! [String: Any]
        #expect((td["type"] as? String) == "server_vad")
        // Tuned: a longer silence window so a mid-thought pause doesn't end the turn mid-sentence.
        #expect((td["silence_duration_ms"] as? Int) == 1000)
    }

    /// The silence window is configurable (so it can be tuned per mic/acoustics).
    @Test func sessionUpdateHonorsConfiguredSilenceWindow() throws {
        let payload = RealtimeSession.sessionUpdate(
            model: .gpt4oTranscribe,
            silenceDurationMs: 700)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let input = (((obj["session"] as! [String: Any])["audio"] as! [String: Any])["input"] as! [String: Any])
        #expect((((input["turn_detection"] as! [String: Any])["silence_duration_ms"]) as? Int) == 700)
    }

    @Test func gptLiveDisablesUnsupportedServerTurnDetection() throws {
        let payload = RealtimeSession.sessionUpdate(
            model: .gptLiveTranscribe,
            silenceDurationMs: 700)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let input = (((obj["session"] as! [String: Any])["audio"] as! [String: Any])["input"]
                     as! [String: Any])
        #expect(input["turn_detection"] is NSNull)
    }

    @Test func gptTranscribeUsesCommittedTurnDetection() throws {
        let payload = RealtimeSession.sessionUpdate(
            model: .gptTranscribe,
            silenceDurationMs: 700)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let input = (((obj["session"] as! [String: Any])["audio"] as! [String: Any])["input"]
                     as! [String: Any])
        #expect(input["turn_detection"] is NSNull)
    }

    @Test func commitEventClassificationIgnoresServerVADAndValidatesClientAcknowledgements() {
        let event: [String: Any] = [
            "type": RealtimeSession.audioBufferCommittedType,
            "item_id": "item-42",
        ]

        #expect(RealtimeSession.audioBufferCommitEvent(from: event, model: .gpt4oTranscribe)
                == .ignored)
        #expect(RealtimeSession.audioBufferCommitEvent(from: event, model: .gptTranscribe)
                == .acknowledgement(itemID: "item-42"))
        #expect(RealtimeSession.audioBufferCommitEvent(
            from: ["type": RealtimeSession.audioBufferCommittedType],
            model: .gptLiveTranscribe) == .malformedAcknowledgement)
        #expect(RealtimeSession.audioBufferCommitEvent(
            from: ["type": RealtimeSession.speechStartedType, "item_id": "item-42"],
            model: .gptLiveTranscribe) == .ignored)
    }

    /// Layer 1 (pre-VAD): noise reduction is sent as an OBJECT `{"type": "near_field"}` nested under
    /// `audio.input` (GA shape — a string here is the documented LiveKit bug the server rejects). It
    /// filters the buffer before VAD, cutting the non-speech blips that trigger phantom transcripts.
    @Test func sessionUpdateIncludesNoiseReductionNearFieldByDefault() throws {
        let payload = RealtimeSession.sessionUpdate(model: .gpt4oTranscribe)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let input = (((obj["session"] as! [String: Any])["audio"] as! [String: Any])["input"] as! [String: Any])
        let nr = try #require(input["noise_reduction"] as? [String: Any])
        #expect(nr["type"] as? String == "near_field")
    }

    /// The mic profile is tunable (far_field for a laptop/room mic), and nil omits the key entirely so
    /// the server applies no filtering.
    @Test func sessionUpdateHonorsConfiguredNoiseReduction() throws {
        func input(_ payload: [String: Any]) throws -> [String: Any] {
            let obj = try JSONSerialization.jsonObject(
                with: try JSONSerialization.data(withJSONObject: payload)) as! [String: Any]
            return (((obj["session"] as! [String: Any])["audio"] as! [String: Any])["input"] as! [String: Any])
        }
        let far = try input(RealtimeSession.sessionUpdate(
            model: .gpt4oTranscribe,
            noiseReduction: "far_field"))
        #expect((far["noise_reduction"] as? [String: Any])?["type"] as? String == "far_field")
        let off = try input(RealtimeSession.sessionUpdate(
            model: .gpt4oTranscribe,
            noiseReduction: nil))
        #expect(off["noise_reduction"] == nil)
    }

    @Test func expectedLanguagesUseEachModelsSupportedWireField() throws {
        func transcription(
            model: OpenAITranscriptionModel,
            languages: [OpenAITranscriptionLanguage]
        ) throws -> [String: Any] {
            let payload = RealtimeSession.sessionUpdate(
                model: model,
                expectedLanguages: languages)
            let data = try JSONSerialization.data(withJSONObject: payload)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let session = object["session"] as! [String: Any]
            let audio = session["audio"] as! [String: Any]
            let input = audio["input"] as! [String: Any]
            return input["transcription"] as! [String: Any]
        }

        let gpt4oEnglish = try transcription(
            model: .gpt4oTranscribe,
            languages: [.english])
        #expect(gpt4oEnglish["language"] as? String == "en")
        #expect(gpt4oEnglish["languages"] == nil)

        let gpt4oMandarin = try transcription(
            model: .gpt4oTranscribe,
            languages: [.mandarinChinese])
        #expect(gpt4oMandarin["language"] as? String == "zh")
        #expect(gpt4oMandarin["languages"] == nil)

        let gpt4oMixed = try transcription(
            model: .gpt4oTranscribe,
            languages: [.english, .mandarinChinese])
        #expect(gpt4oMixed["language"] == nil)
        #expect(gpt4oMixed["languages"] == nil)

        let transcribeEnglish = try transcription(
            model: .gptTranscribe,
            languages: [.english])
        #expect(transcribeEnglish["language"] == nil)
        #expect(transcribeEnglish["languages"] as? [String] == ["en"])

        let transcribeMandarin = try transcription(
            model: .gptTranscribe,
            languages: [.mandarinChinese])
        #expect(transcribeMandarin["language"] == nil)
        #expect(transcribeMandarin["languages"] as? [String] == ["zh-cn"])

        let transcribeMixed = try transcription(
            model: .gptTranscribe,
            languages: [.mandarinChinese, .english, .mandarinChinese])
        #expect(transcribeMixed["language"] == nil)
        #expect(transcribeMixed["languages"] as? [String] == ["en", "zh-cn"])

        let transcribeAutomatic = try transcription(
            model: .gptTranscribe,
            languages: [])
        #expect(transcribeAutomatic["language"] == nil)
        #expect(transcribeAutomatic["languages"] == nil)

        let liveEnglish = try transcription(
            model: .gptLiveTranscribe,
            languages: [.english])
        #expect(liveEnglish["language"] == nil)
        #expect(liveEnglish["languages"] as? [String] == ["en"])

        let liveMandarin = try transcription(
            model: .gptLiveTranscribe,
            languages: [.mandarinChinese])
        #expect(liveMandarin["language"] == nil)
        #expect(liveMandarin["languages"] as? [String] == ["zh-cn"])

        let liveMixed = try transcription(
            model: .gptLiveTranscribe,
            languages: [.english, .mandarinChinese])
        #expect(liveMixed["language"] == nil)
        #expect(liveMixed["languages"] as? [String] == ["en", "zh-cn"])

        let liveAutomatic = try transcription(
            model: .gptLiveTranscribe,
            languages: [])
        #expect(liveAutomatic["language"] == nil)
        #expect(liveAutomatic["languages"] == nil)
    }

    @Test func newestModelsUseFixedRoleContextWithoutVocabularyHints() throws {
        func transcription(
            model: OpenAITranscriptionModel,
            speaker: Speaker
        ) throws -> [String: Any] {
            let payload = RealtimeSession.sessionUpdate(model: model, speaker: speaker)
            let data = try JSONSerialization.data(withJSONObject: payload)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let session = object["session"] as! [String: Any]
            let audio = session["audio"] as! [String: Any]
            let input = audio["input"] as! [String: Any]
            return input["transcription"] as! [String: Any]
        }

        let legacy = try transcription(model: .gpt4oTranscribe, speaker: .me)
        #expect(legacy["prompt"] == nil)
        #expect(legacy["keywords"] == nil)
        #expect(legacy["delay"] == nil)

        let committed = try transcription(model: .gptTranscribe, speaker: .me)
        #expect(committed["prompt"] as? String == JarvisPrompts.Transcription.context(for: .me))
        #expect((committed["prompt"] as? String)?.contains("microphone") == true)
        #expect(committed["keywords"] == nil)
        #expect(committed["delay"] == nil)

        let live = try transcription(model: .gptLiveTranscribe, speaker: .them)
        #expect(live["prompt"] as? String == JarvisPrompts.Transcription.context(for: .them))
        #expect((live["prompt"] as? String)?.contains("system audio") == true)
        #expect(live["keywords"] == nil)
        #expect(live["delay"] as? String == "low")
        #expect((committed["prompt"] as? String) != (live["prompt"] as? String))
    }

    /// Keywords are opt-in vocabulary hints: absent by default (matching the prior no-keywords
    /// behavior), sent only alongside `prompt` for the committed-turn models, and never for GPT-4o
    /// Transcribe, which has no wire field for either.
    @Test func keywordsOnlySendToCommittedTurnModels() throws {
        func transcription(model: OpenAITranscriptionModel, keywords: [String]) throws -> [String: Any] {
            let payload = RealtimeSession.sessionUpdate(model: model, keywords: keywords)
            let data = try JSONSerialization.data(withJSONObject: payload)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let session = object["session"] as! [String: Any]
            let audio = session["audio"] as! [String: Any]
            let input = audio["input"] as! [String: Any]
            return input["transcription"] as! [String: Any]
        }

        let gpt4o = try transcription(model: .gpt4oTranscribe, keywords: ["Kubernetes", "gRPC"])
        #expect(gpt4o["keywords"] == nil)

        let committed = try transcription(model: .gptTranscribe, keywords: ["Kubernetes", "gRPC"])
        #expect(committed["keywords"] as? [String] == ["Kubernetes", "gRPC"])

        let live = try transcription(model: .gptLiveTranscribe, keywords: ["Ada Lovelace"])
        #expect(live["keywords"] as? [String] == ["Ada Lovelace"])

        let empty = try transcription(model: .gptTranscribe, keywords: [])
        #expect(empty["keywords"] == nil)
    }

    @Test func detectedLanguageCodesPreserveAbsentAndEmptyMeanings() {
        let type = RealtimeSession.completedTranscriptionType
        #expect(RealtimeSession.detectedLanguageCodes(from: [
            "type": type,
            "languages": [["code": "fr"], ["code": " zh-cn "]],
        ]) == ["fr", "zh-cn"])
        #expect(RealtimeSession.detectedLanguageCodes(from: [
            "type": type,
            "languages": [],
        ]) == [])
        #expect(RealtimeSession.detectedLanguageCodes(from: ["type": type]) == nil)
        #expect(RealtimeSession.detectedLanguageCodes(from: [
            "type": RealtimeSession.deltaTranscriptionType,
            "languages": [["code": "en"]],
        ]) == nil)
        #expect(RealtimeSession.detectedLanguageCodes(from: [
            "type": type,
            "languages": "en",
        ]) == nil)
    }

    @Test func appendAudioShape() {
        let ev = RealtimeSession.appendAudio(base64PCM: "AAAA")
        #expect(ev["type"] as? String == "input_audio_buffer.append")
        #expect(ev["audio"] as? String == "AAAA")
    }

    @Test func commitAudioShape() {
        let event = RealtimeSession.commitAudio(eventID: "commit-7")
        #expect(event["type"] as? String == "input_audio_buffer.commit")
        #expect(event["event_id"] as? String == "commit-7")
    }

    @Test func configuredSessionEventRequiresUpdateAcknowledgement() {
        #expect(RealtimeSession.isConfiguredSessionEventType("session.updated"))
        #expect(RealtimeSession.isConfiguredSessionEventType("transcription_session.updated"))
        #expect(!RealtimeSession.isConfiguredSessionEventType("session.created"))
        #expect(!RealtimeSession.isConfiguredSessionEventType("transcription_session.created"))
    }

    /// The real `session_expired` wire event (the same JSON the socket delivers at the ~60-min cap) is
    /// recognized as an expected rotation, so the transcriber logs it calmly instead of as a fault.
    @Test func isSessionExpiredMatchesTheServerExpiryEvent() throws {
        let wire = "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"code\":\"session_expired\",\"message\":\"Your session hit the maximum duration of 60 minutes.\"}}"
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any])
        #expect(RealtimeSession.isSessionExpired(obj))
    }

    /// Other errors, non-error events, and malformed payloads are NOT rotations — they stay visible as
    /// real faults rather than being quietly swallowed.
    @Test func isSessionExpiredRejectsEverythingElse() {
        #expect(!RealtimeSession.isSessionExpired(["type": "error", "error": ["code": "invalid_api_key"]]))
        #expect(!RealtimeSession.isSessionExpired(["type": "error"]))                       // no error object
        #expect(!RealtimeSession.isSessionExpired(["type": "error", "error": ["message": "x"]]))  // error, but no code
        #expect(!RealtimeSession.isSessionExpired(["type": "error", "error": ["code": 5]]))  // non-string code
        #expect(!RealtimeSession.isSessionExpired(["type": "transcription_session.created"]))
        #expect(!RealtimeSession.isSessionExpired([:]))
    }

    @Test func terminalTranscriptionFailureClassifiesBreakingAccountErrors() {
        func event(code: String? = nil, type: String? = nil) -> [String: Any] {
            var error: [String: Any] = [:]
            if let code { error["code"] = code }
            if let type { error["type"] = type }
            return ["type": RealtimeSession.failedTranscriptionType, "error": error]
        }

        #expect(RealtimeSession.terminalTranscriptionFailure(from: event(code: "insufficient_quota"))
                == .quotaExceeded)
        #expect(RealtimeSession.terminalTranscriptionFailure(from: event(code: "invalid_api_key"))
                == .authenticationFailed)
        #expect(RealtimeSession.terminalTranscriptionFailure(from: event(type: "authentication_error"))
                == .authenticationFailed)
        #expect(RealtimeSession.terminalTranscriptionFailure(from: event(type: "permission_error"))
                == .accessDenied)
        #expect(RealtimeSession.terminalTranscriptionFailure(from: event(code: "model_not_found"))
                == .configurationRejected)
        #expect(RealtimeSession.terminalTranscriptionFailure(from: [
            "type": "error",
            "error": ["code": "insufficient_quota"],
        ]) == .quotaExceeded)
        #expect(RealtimeSession.terminalTranscriptionFailure(from: [
            "type": "error",
            "error": [
                "code": "invalid_value",
                "param": "session.audio.input.turn_detection",
            ],
        ]) == .configurationRejected)
    }

    @Test func terminalTranscriptionFailureLeavesUtteranceAndTransientErrorsRecoverable() {
        func event(code: String, type: String = "transcription_error") -> [String: Any] {
            [
                "type": RealtimeSession.failedTranscriptionType,
                "error": ["code": code, "type": type],
            ]
        }

        #expect(RealtimeSession.terminalTranscriptionFailure(from: event(code: "audio_unintelligible")) == nil)
        #expect(RealtimeSession.terminalTranscriptionFailure(from: event(code: "rate_limit_exceeded")) == nil)
        #expect(RealtimeSession.terminalTranscriptionFailure(from: event(code: "server_error")) == nil)
        #expect(RealtimeSession.terminalTranscriptionFailure(from: [
            "type": RealtimeSession.completedTranscriptionType,
            "error": ["code": "insufficient_quota"],
        ]) == nil)
        #expect(RealtimeSession.terminalTranscriptionFailure(from: [
            "type": RealtimeSession.failedTranscriptionType,
        ]) == nil)
        #expect(RealtimeSession.terminalTranscriptionFailure(from: [
            "type": "error",
            "error": ["code": "invalid_value", "param": "item.audio"],
        ]) == nil)
    }
}
