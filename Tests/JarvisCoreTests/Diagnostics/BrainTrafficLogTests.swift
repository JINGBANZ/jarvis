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
}
