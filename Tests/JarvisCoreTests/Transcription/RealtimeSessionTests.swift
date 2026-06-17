import Foundation
import Testing
@testable import JarvisCore

@Suite struct RealtimeSessionTests {
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

    @Test func appendAudioShape() {
        let ev = RealtimeSession.appendAudio(base64PCM: "AAAA")
        #expect(ev["type"] as? String == "input_audio_buffer.append")
        #expect(ev["audio"] as? String == "AAAA")
    }
}
