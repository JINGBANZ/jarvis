import Testing
import Foundation
@testable import JarvisCore

@Suite struct BrainTrafficLogTests {
    /// Read the traffic file back as parsed JSON lines.
    private func lines(in dir: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: dir.appendingPathComponent(BrainTrafficLog.filename),
                              encoding: .utf8)
        return try text.split(separator: "\n", omittingEmptySubsequences: true).map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    @Test func recordPersistsRoundTripWithImagesRedacted() throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = BrainTrafficLog(); log.enable(directory: dir)
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.5",
            "input": [
                ["role": "user", "content": [["type": "input_text", "text": "hi"]]],
                ["role": "user", "content": [["type": "input_image",
                                              "image_url": "data:image/jpeg;base64,\(TestFixtures.tinyJpegBase64)"]]],
            ],
        ])
        let response = Data(#"{"status":"completed","usage":{"input_tokens":10}}"#.utf8)
        log.record(tag: "coach", request: request, response: response, status: 200, latencyMs: 812)
        log.flush()

        let entry = try #require(try lines(in: dir).first)
        #expect(entry["tag"] as? String == "coach")
        #expect(entry["status"] as? Int == 200)
        #expect(entry["ms"] as? Int == 812)
        #expect(entry["error"] == nil)
        let req = try #require(entry["request"] as? [String: Any])
        let input = try #require(req["input"] as? [[String: Any]])
        let textPart = try #require((input[0]["content"] as? [[String: Any]])?.first)
        #expect(textPart["text"] as? String == "hi")   // non-image content untouched
        let imagePart = try #require((input[1]["content"] as? [[String: Any]])?.first)
        let url = try #require(imagePart["image_url"] as? String)
        #expect(url.hasPrefix("[base64 image omitted"))
        #expect(!url.contains("data:image"))
        let resp = try #require(entry["response"] as? [String: Any])
        #expect(resp["status"] as? String == "completed")
    }

    @Test func transportErrorRecordsRequestAndErrorWithoutResponse() throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = BrainTrafficLog(); log.enable(directory: dir)
        log.record(tag: "coach", request: Data(#"{"model":"gpt-5.5"}"#.utf8),
                   response: nil, status: nil, latencyMs: 60_000, error: "timed out")
        log.flush()

        let entry = try #require(try lines(in: dir).first)
        #expect(entry["error"] as? String == "timed out")
        #expect(entry["status"] == nil)
        #expect(entry["response"] == nil)
        #expect((entry["request"] as? [String: Any])?["model"] as? String == "gpt-5.5")
    }

    @Test func enableCreatesOwnerOnlyFileImmediately() throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = BrainTrafficLog(); log.enable(directory: dir)
        let url = dir.appendingPathComponent(BrainTrafficLog.filename)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    @Test func recordIsNoOpWhenDisabled() {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = BrainTrafficLog()                     // never enabled
        log.record(tag: "coach", request: Data("{}".utf8), response: nil, status: nil, latencyMs: 1)
        log.flush()
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(BrainTrafficLog.filename).path))
    }

    @Test func redactionWalksNestedStructuresAndLeavesOtherStringsAlone() {
        let redacted = BrainTrafficLog.redactingImages([
            "plain": "data-driven text",
            "nested": [["image_url": "data:image/png;base64,AAAA"]],
        ]) as? [String: Any]
        #expect(redacted?["plain"] as? String == "data-driven text")
        let inner = (redacted?["nested"] as? [[String: Any]])?.first
        #expect((inner?["image_url"] as? String)?.hasPrefix("[base64 image omitted") == true)
    }

    @Test func coachingRequestContextLinksTheWireCallToItsAttempt() throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = BrainTrafficLog(); log.enable(directory: dir)
        let context = CoachingAttemptLog.requestContext(
            attemptID: 7,
            wake: .pendingWork,
            reason: .turnEnd,
            phase: .captureScreenContinuation,
            sequence: 2)

        CoachingAttemptLog.$currentRequest.withValue(context) {
            log.record(
                tag: "coach",
                request: Data(#"{"model":"gpt-5.5"}"#.utf8),
                response: Data(#"{"status":"completed"}"#.utf8),
                status: 200,
                latencyMs: 12)
            log.record(
                tag: "summarizer",
                request: Data(#"{"model":"gpt-5.4-mini"}"#.utf8),
                response: Data(#"{"status":"completed"}"#.utf8),
                status: 200,
                latencyMs: 8)
        }
        log.flush()

        let entries = try lines(in: dir)
        let entry = try #require(entries.first)
        let provenance = try #require(entry["coach_attempt"] as? [String: Any])
        #expect(provenance["id"] as? Int == 7)
        #expect(provenance["trigger"] as? String == "pending_work")
        #expect(provenance["source_trigger"] as? String == "turn_end")
        #expect(provenance["phase"] as? String == "capture_screen_continuation")
        #expect(provenance["sequence"] as? Int == 2)
        #expect(entry["record_kind"] as? String == "provider_call")
        #expect(entries[1]["coach_attempt"] == nil)
    }
}
