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
        let payload = RealtimeSession.sessionUpdate(model: "gpt-4o-transcribe")
        let data = try JSONSerialization.data(withJSONObject: payload)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["type"] as? String == "session.update")
        let session = obj["session"] as! [String: Any]
        #expect(session["type"] as? String == "transcription")
        let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
        #expect(((input["format"] as! [String: Any])["rate"] as? Int) == 24_000)
        #expect(((input["transcription"] as! [String: Any])["model"] as? String) == "gpt-4o-transcribe")
        let td = input["turn_detection"] as! [String: Any]
        #expect((td["type"] as? String) == "server_vad")
        // Tuned: a longer silence window so a mid-thought pause doesn't end the turn mid-sentence.
        #expect((td["silence_duration_ms"] as? Int) == 1000)
    }

    /// The silence window is configurable (so it can be tuned per mic/acoustics).
    @Test func sessionUpdateHonorsConfiguredSilenceWindow() throws {
        let payload = RealtimeSession.sessionUpdate(model: "gpt-4o-transcribe", silenceDurationMs: 700)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let input = (((obj["session"] as! [String: Any])["audio"] as! [String: Any])["input"] as! [String: Any])
        #expect((((input["turn_detection"] as! [String: Any])["silence_duration_ms"]) as? Int) == 700)
    }

    /// Layer 1 (pre-VAD): noise reduction is sent as an OBJECT `{"type": "near_field"}` nested under
    /// `audio.input` (GA shape — a string here is the documented LiveKit bug the server rejects). It
    /// filters the buffer before VAD, cutting the non-speech blips that trigger phantom transcripts.
    @Test func sessionUpdateIncludesNoiseReductionNearFieldByDefault() throws {
        let payload = RealtimeSession.sessionUpdate(model: "gpt-4o-transcribe")
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
        let far = try input(RealtimeSession.sessionUpdate(model: "m", noiseReduction: "far_field"))
        #expect((far["noise_reduction"] as? [String: Any])?["type"] as? String == "far_field")
        let off = try input(RealtimeSession.sessionUpdate(model: "m", noiseReduction: nil))
        #expect(off["noise_reduction"] == nil)
    }

    @Test func appendAudioShape() {
        let ev = RealtimeSession.appendAudio(base64PCM: "AAAA")
        #expect(ev["type"] as? String == "input_audio_buffer.append")
        #expect(ev["audio"] as? String == "AAAA")
    }
}
