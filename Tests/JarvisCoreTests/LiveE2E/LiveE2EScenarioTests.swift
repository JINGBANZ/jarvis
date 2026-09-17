import Foundation
import Testing
@testable import JarvisCore

@Suite("Live e2e scenarios")
struct LiveE2EScenarioTests {
    private static let liveTests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../JarvisLiveTests", isDirectory: true)
        .standardizedFileURL

    @Test(
        "every shipped scenario decodes and validates",
        arguments: ["A", "B", "C", "R", "F01-system", "F01-microphone", "F02"])
    func shippedScenarioValidates(id: String) throws {
        let url = Self.liveTests.appendingPathComponent("Scenarios/\(id).json")
        let fixtures = Self.liveTests.appendingPathComponent("Fixtures", isDirectory: true)
        try #require(
            FileManager.default.fileExists(atPath: url.path), "Missing scenario file: \(url.path)")

        let scenario = try LiveE2EScenario.load(from: url, fixturesDirectory: fixtures)

        #expect(scenario.id == id)
    }

    @Test("scenario A ships the specified settings and steps")
    func scenarioAMatchesItsSpecification() throws {
        let scenario = try LiveE2EScenario.load(
            from: Self.liveTests.appendingPathComponent("Scenarios/A.json"),
            fixturesDirectory: Self.liveTests.appendingPathComponent("Fixtures", isDirectory: true))

        #expect(scenario.audio == .fixture)
        #expect(scenario.brain == .init(primary: .claudeSubscription, fallbacks: []))
        #expect(scenario.capabilities == .init(disabledTools: [], disabledSkills: []))
        #expect(scenario.prepNotes == "prep-notes.md")
        #expect(scenario.transcription == .init(model: .gpt4oTranscribe, key: .standard))
        #expect(scenario.voices == .init(them: "Samantha", me: "Daniel"))
        #expect(scenario.steps == [
            .screen(fixture: "coding-problem.jpg"),
            .press(.hint),
            them("Great, thanks for joining. We'll get started in just a minute."),
            them("Tell me about a time you disagreed with a teammate."),
            .switchBrain(.openAI),
            them("Let's move on to design: our product search is slow, and we are redesigning it. We agreed on twenty thousand searches per second, p99 under three hundred milliseconds, and results up to a minute stale, behind one search API. Now sketch the high-level architecture: which components would you put in, and what is the read path for one request?"),
            .switchBrain(.codexSubscription),
            them("Tell me about a time you pushed back on a decision from your manager."),
            .say(.init(speaker: .me, text: "Jarvis, how can I solve this in one pass?"),
                 overlap: nil, whileAttemptRunning: false),
            .press(.hint),
            .press(.showCode),
            .say(
                .init(
                    speaker: .them,
                    text: "Back to the slow search endpoint from earlier. Say we redesign that service for a hundred times the traffic. Walk me through the components you would put in, and the read path for one request."),
                overlap: .init(speaker: .me, text: "Sure.", afterSeconds: 3.0),
                whileAttemptRunning: false),
            .say(
                .init(speaker: .them, text: "How would you handle cache invalidation when a record is updated?"),
                overlap: nil,
                whileAttemptRunning: true),
            .stop,
        ])
    }

    /// Live checks C07 and C08 count searches, so each story must come back whole to its own query
    /// and the teammate search must not already return the manager story.
    @Test("scenario A's prep notes return each behavioral story whole to its own search")
    func prepNotesReturnEachStoryWholeToItsOwnSearch() throws {
        let notes = try String(
            contentsOf: Self.liveTests.appendingPathComponent("Fixtures/prep-notes.md"), encoding: .utf8)
        let chunks = PrepMaterialChunker.chunk(text: notes, sourceDisplayName: "prep-notes.md")
        let index = PrepMaterialIndex(chunks: chunks)
        let layout = chunks.map { "\($0.text.split(separator: " ").count) words: \($0.text.prefix(30))" }
        func carriesManagerStory(_ result: PrepMaterialSearchResult) -> Bool {
            result.text.contains("Marcus") || result.text.contains("feature flag")
        }
        func isWholeManagerStory(_ result: PrepMaterialSearchResult) -> Bool {
            result.text.contains("Marcus Webb") && result.text.contains("zero data-loss")
        }
        func isWholeTeammateStory(_ result: PrepMaterialSearchResult) -> Bool {
            result.text.contains("my teammate Priya") && result.text.contains("0.01%")
        }

        #expect(chunks.count >= 4, "\(layout)")
        for query in [
            "time you disagreed with a teammate", "disagreed with a teammate",
            "disagreed with a teammate conflict story", "disagreed with a teammate conflict",
            "teammate disagreement", "conflict with a teammate",
        ] {
            let results = index.search(query: query)
            #expect(!results.contains(where: carriesManagerStory),
                    "\"\(query)\" returned the manager story; chunks: \(layout)")
            #expect(results.contains(where: isWholeTeammateStory),
                    "\"\(query)\" did not return the whole teammate story; chunks: \(layout)")
        }
        for query in [
            "time you pushed back on a decision from your manager",
            "pushed back on manager decision story",
            "pushed back on manager decision evidence alternative outcome",
            "pushed back on manager decision launch data loss bugs staged rollout",
        ] {
            #expect(index.search(query: query).first.map(isWholeManagerStory) == true,
                    "\"\(query)\" did not rank the whole manager story first; chunks: \(layout)")
        }
    }

    @Test("scenario B ships its capability switches")
    func scenarioBMatchesItsSpecification() throws {
        let fixtures = Self.liveTests.appendingPathComponent("Fixtures", isDirectory: true)
        let b = try LiveE2EScenario.load(
            from: Self.liveTests.appendingPathComponent("Scenarios/B.json"),
            fixturesDirectory: fixtures)

        #expect(b.brain == .init(primary: .claudeSubscription, fallbacks: []))
        #expect(b.capabilities == .init(
            disabledTools: ["search_prep_notes"],
            disabledSkills: ["behavioral", "system-design", "coding-with-ai"]))
    }

    @Test("every field and step kind decodes into the model")
    func decodesEveryField() throws {
        let fixtures = try makeFixtures()
        defer { try? FileManager.default.removeItem(at: fixtures) }
        let json = #"""
        {
          "id": "Mixed-1",
          "audio": "fixture",
          "brain": { "primary": "claude-subscription", "fallbacks": ["openai", "codex-subscription"] },
          "capabilities": { "disabledTools": ["search_prep_notes"], "disabledSkills": ["coding"] },
          "prepNotes": "prep-notes.md",
          "transcription": { "model": "gpt-transcribe", "key": "invalid" },
          "voices": { "them": "Samantha", "me": "Daniel" },
          "steps": [
            { "screen": "coding-problem.jpg" },
            { "press": "explainMore" },
            { "press": "showCode" },
            { "say": { "speaker": "me", "text": "One." }, "overlap": { "speaker": "them", "text": "Two.", "afterSeconds": 0.5 } },
            { "say": { "speaker": "them", "text": "Three." }, "whileAttemptRunning": true },
            { "switchBrain": "openai" },
            { "switchBrain": "claude-subscription" },
            { "stop": true }
          ]
        }
        """#

        let scenario = try LiveE2EScenario.decode(Data(json.utf8), fixturesDirectory: fixtures)

        #expect(scenario.id == "Mixed-1")
        #expect(scenario.audio == .fixture)
        #expect(scenario.brain == .init(primary: .claudeSubscription, fallbacks: [.openAI, .codexSubscription]))
        #expect(scenario.capabilities == .init(
            disabledTools: ["search_prep_notes"], disabledSkills: ["coding"]))
        #expect(scenario.prepNotes == "prep-notes.md")
        #expect(scenario.transcription == .init(model: .gptTranscribe, key: .invalid))
        #expect(scenario.steps == [
            .screen(fixture: "coding-problem.jpg"),
            .press(.explainMore),
            .press(.showCode),
            .say(.init(speaker: .me, text: "One."),
                 overlap: .init(speaker: .them, text: "Two.", afterSeconds: 0.5),
                 whileAttemptRunning: false),
            .say(.init(speaker: .them, text: "Three."), overlap: nil, whileAttemptRunning: true),
            .switchBrain(.openAI),
            .switchBrain(.claudeSubscription),
            .stop,
        ])
    }

    @Test("a null prepNotes decodes as empty")
    func nullPrepNotesDecodesEmpty() throws {
        let fixtures = try makeFixtures()
        defer { try? FileManager.default.removeItem(at: fixtures) }

        let scenario = try LiveE2EScenario.decode(
            Data(Self.scenario().utf8), fixturesDirectory: fixtures)

        #expect(scenario.prepNotes == nil)
        #expect(scenario.steps == [.stop])
    }

    struct RejectedCase: Sendable, CustomTestStringConvertible {
        let name: String
        let json: String
        /// Text the rejection description must contain.
        let fragment: String

        var testDescription: String { name }
    }

    private static let say = #"{ "say": { "speaker": "them", "text": "Hello there." } }"#
    private static let stop = #"{ "stop": true }"#
    private static let overlap = #"{ "speaker": "me", "text": "Sure.", "afterSeconds": 1.0 }"#

    static let rejectedCases: [RejectedCase] = [
        RejectedCase(
            name: "an unknown step key",
            json: scenario(steps: #"[{ "shout": "hi" }, \#(stop)]"#),
            fragment: #"steps[0]: unknown key "shout""#),
        RejectedCase(
            name: "a step with no primary key",
            json: scenario(steps: "[{}, \(stop)]"),
            fragment: "steps[0]: needs exactly one of"),
        RejectedCase(
            name: "a step with only a modifier key",
            json: scenario(steps: #"[{ "whileAttemptRunning": false }, \#(stop)]"#),
            fragment: "steps[0]: needs exactly one of"),
        RejectedCase(
            name: "a step with two primary keys",
            json: scenario(steps: #"[\#(say), { "press": "hint", "screen": "coding-problem.jpg" }, \#(stop)]"#),
            fragment: "steps[1]: needs exactly one of"),
        RejectedCase(
            name: "an empty step list",
            json: scenario(steps: "[]"),
            fragment: "steps must not be empty"),
        RejectedCase(
            name: "whileAttemptRunning on the first step",
            json: scenario(
                steps: #"[{ "say": { "speaker": "them", "text": "Hi." }, "whileAttemptRunning": true }, \#(stop)]"#),
            fragment: "steps[0]: whileAttemptRunning cannot mark the first step"),
        RejectedCase(
            name: "overlap on a press",
            json: scenario(steps: #"[\#(say), { "press": "hint", "overlap": \#(overlap) }, \#(stop)]"#),
            fragment: "steps[1]: overlap and whileAttemptRunning apply only to a say step"),
        RejectedCase(
            name: "whileAttemptRunning on a screen",
            json: scenario(
                steps: #"[\#(say), { "screen": "coding-problem.jpg", "whileAttemptRunning": true }, \#(stop)]"#),
            fragment: "steps[1]: overlap and whileAttemptRunning apply only to a say step"),
        RejectedCase(
            name: "a stop before the last step",
            json: scenario(steps: "[\(say), \(stop), \(say), \(stop)]"),
            fragment: "steps[1]: stop must be the last step"),
        RejectedCase(
            name: "a last step that is not stop",
            json: scenario(steps: "[\(say), \(say)]"),
            fragment: "steps[1]: the last step must be stop"),
        RejectedCase(
            name: "a stop that is not true",
            json: scenario(steps: #"[{ "stop": false }]"#),
            fragment: "steps[0]: stop must be true"),
        RejectedCase(
            name: "switchBrain naming the primary brain",
            json: scenario(steps: #"[{ "switchBrain": "codex-subscription" }, \#(stop)]"#),
            fragment: #"steps[0]: switchBrain names the current brain "codex-subscription""#),
        RejectedCase(
            name: "switchBrain naming the brain a previous switch selected",
            json: scenario(
                steps: #"[{ "switchBrain": "openai" }, \#(say), { "switchBrain": "openai" }, \#(stop)]"#),
            fragment: #"steps[2]: switchBrain names the current brain "openai""#),
        RejectedCase(
            name: "a screen fixture with a path separator",
            json: scenario(steps: #"[{ "screen": "sub/coding-problem.jpg" }, \#(stop)]"#),
            fragment: "steps[0].screen must be a plain file name"),
        RejectedCase(
            name: "a screen fixture that climbs out",
            json: scenario(steps: #"[{ "screen": ".." }, \#(stop)]"#),
            fragment: "steps[0].screen must be a plain file name"),
        RejectedCase(
            name: "a screen fixture that does not exist",
            json: scenario(steps: #"[{ "screen": "absent.jpg" }, \#(stop)]"#),
            fragment: "steps[0].screen names no file"),
        RejectedCase(
            name: "a screen fixture that is a directory",
            json: scenario(steps: #"[{ "screen": "folder" }, \#(stop)]"#),
            fragment: "steps[0].screen names no file"),
        RejectedCase(
            name: "a screen fixture that is not a JPEG",
            json: scenario(steps: #"[{ "screen": "prep-notes.md" }, \#(stop)]"#),
            fragment: "steps[0].screen must be a JPEG image"),
        RejectedCase(
            name: "prepNotes with a path separator",
            json: scenario(prepNotes: #""../prep-notes.md""#),
            fragment: "prepNotes must be a plain file name"),
        RejectedCase(
            name: "a me line when the scenario plays no microphone",
            json: scenario(
                audio: "fixture-no-microphone",
                steps: #"[{ "say": { "speaker": "me", "text": "Hi." } }, \#(stop)]"#),
            fragment: #"steps[0]: "fixture-no-microphone" audio cannot speak as me"#),
        RejectedCase(
            name: "an overlap from them when the scenario plays no system audio",
            json: scenario(
                audio: "fixture-no-system",
                steps: #"[{ "say": { "speaker": "me", "text": "Hi." }, "overlap": { "speaker": "them", "text": "Sure.", "afterSeconds": 1 } }, \#(stop)]"#),
            fragment: #"steps[0]: "fixture-no-system" audio cannot speak as them"#),
        RejectedCase(
            name: "a line when the scenario hears the device",
            json: scenario(
                audio: "device",
                steps: #"[{ "say": { "speaker": "them", "text": "Hi." } }, \#(stop)]"#),
            fragment: #"steps[0]: "device" audio cannot speak as them"#),
        RejectedCase(
            name: "prepNotes that does not exist",
            json: scenario(prepNotes: #""absent.md""#),
            fragment: "prepNotes names no file"),
        RejectedCase(
            name: "an unknown transcription key",
            json: scenario(key: "expired"),
            fragment: #"transcription.key: unknown value "expired""#),
        RejectedCase(
            name: "a zero overlap delay",
            json: scenario(
                steps: #"[{ "say": { "speaker": "them", "text": "Hi." }, "overlap": { "speaker": "me", "text": "Sure.", "afterSeconds": 0 } }, \#(stop)]"#),
            fragment: "steps[0]: overlap.afterSeconds must be positive"),
        RejectedCase(
            name: "a negative overlap delay",
            json: scenario(
                steps: #"[\#(say), { "say": { "speaker": "them", "text": "Hi." }, "overlap": { "speaker": "me", "text": "Sure.", "afterSeconds": -1.5 } }, \#(stop)]"#),
            fragment: "steps[1]: overlap.afterSeconds must be positive"),
        RejectedCase(
            name: "an empty id",
            json: scenario(id: ""),
            fragment: "id must be non-empty letters, digits, and -"),
        RejectedCase(
            name: "an id with an underscore",
            json: scenario(id: "A_1"),
            fragment: "id must be non-empty letters, digits, and -"),
        RejectedCase(
            name: "an id with a path separator",
            json: scenario(id: "A/B"),
            fragment: "id must be non-empty letters, digits, and -"),
        RejectedCase(
            name: "an id with a non-ASCII letter",
            json: scenario(id: "Å"),
            fragment: "id must be non-empty letters, digits, and -"),
    ]

    @Test("each validation rule rejects its violation", arguments: rejectedCases)
    func rejects(_ rejected: RejectedCase) throws {
        let fixtures = try makeFixtures()
        defer { try? FileManager.default.removeItem(at: fixtures) }

        let description = try #require(rejection(of: rejected.json, fixtures: fixtures))

        #expect(description.contains(rejected.fragment), "\(description)")
    }

    private static func scenario(
        id: String = "T-1",
        audio: String = "fixture",
        prepNotes: String = "null",
        key: String = "standard",
        steps: String = "[\(stop)]"
    ) -> String {
        return #"""
        {
          "id": "\#(id)",
          "audio": "\#(audio)",
          "brain": { "primary": "codex-subscription", "fallbacks": [] },
          "capabilities": { "disabledTools": [], "disabledSkills": [] },
          "prepNotes": \#(prepNotes),
          "transcription": { "model": "gpt-4o-transcribe", "key": "\#(key)" },
          "voices": { "them": "Samantha", "me": "Daniel" },
          "steps": \#(steps)
        }
        """#
    }

    private func them(_ text: String) -> LiveE2EScenario.Step {
        .say(.init(speaker: .them, text: text), overlap: nil, whileAttemptRunning: false)
    }

    private func makeFixtures() throws -> URL {
        let fixtures = ActivityLogTests.tmp()
        try Data([0xFF, 0xD8, 0xFF]).write(to: fixtures.appendingPathComponent("coding-problem.jpg"))
        try Data("# Notes\n".utf8).write(to: fixtures.appendingPathComponent("prep-notes.md"))
        try FileManager.default.createDirectory(
            at: fixtures.appendingPathComponent("folder", isDirectory: true),
            withIntermediateDirectories: true)
        return fixtures
    }

    private func rejection(of json: String, fixtures: URL) -> String? {
        do {
            _ = try LiveE2EScenario.decode(Data(json.utf8), fixturesDirectory: fixtures)
            return nil
        } catch let failure as LiveE2EScenario.Failure {
            return failure.description
        } catch {
            return "unexpected error: \(error)"
        }
    }
}
