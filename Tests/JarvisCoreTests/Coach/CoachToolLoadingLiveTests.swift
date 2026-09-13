import Foundation
import Testing
@testable import JarvisCore
import JarvisBrainProviders

/// Opt-in smoke for the one thing only a real model can answer: does it load a deferred tool it was
/// offered one line of, and use it, inside a single coaching attempt?
///
/// The normal Gate leaves this inert. Run it with `JARVIS_LIVE_CAPABILITY_PROVIDER` set to `openai`,
/// `claude-code`, `codex-cli`, or `all` to make billed/subscription-backed requests through the real
/// coaching kernel: the real composed capabilities, the real system prompt, the real tool loop, and
/// a real BM25 prep index. Only screen capture and the overlay are faked, because a live model's
/// choice does not depend on them. TCC permissions, audio capture, the Settings card, and diagram
/// rendering stay with the app's own live smoke (wiki/build-and-run.md).
@Suite(.serialized) struct CoachToolLoadingLiveTests {
    /// Both are direct addresses, so the action policy requires a reply and the load rule fires
    /// ahead of it; an interviewer-only question would let the model stay silent and prove nothing.
    /// The first names the prepared notes, which is the cue the catalog line describes, and is what
    /// the mechanism is asserted against. The second only implies them, and is measured rather than
    /// asserted: whether a model reads "design a rate limiter" as resembling a prepared topic is its
    /// judgment, and the providers disagree.
    private static let explicitQuestion =
        "Jarvis, they just asked me to design a rate limiter. What did I prepare on this?"
    private static let implicitQuestion =
        "Jarvis, they just asked me to design a rate limiter. What should I cover?"
    /// Direct addresses again, one clearly behavioral and one clearly a design round, so the only
    /// open question is which skill the model reaches for.
    private static let behavioralQuestion =
        "Jarvis, they just asked me to tell them about a time I disagreed with my manager. How should I answer?"
    private static let designQuestion =
        "Jarvis, they just asked me to design a URL shortener. Where should I start?"

    /// Text worth finding: specific enough that a tip built on it is visibly built on it.
    private static let notes = PrepMaterialIndex(chunks: [
        PrepMaterialChunk(
            sourceDisplayName: "system-design.md",
            text: """
            Rate limiter notes. My worked example is a token bucket sized at 100 tokens refilling at
            10 per second per API key, kept in Redis with a Lua script so the read and the decrement
            are one atomic step. I say the sliding window log is more accurate but costs memory per
            request, and that the bucket's burst allowance is the tradeoff I want to talk about.
            """),
        PrepMaterialChunk(
            sourceDisplayName: "system-design.md",
            text: """
            Consistent hashing notes. Virtual nodes smooth the ring when a shard leaves, and I
            compare that against a fixed modulo scheme that reshuffles every key.
            """),
    ])

    @Test func theModelLoadsPrepSearchAndUsesItInOneAttempt() async throws {
        for provider in Self.requestedProviders() { try await verify(provider) }
    }

    /// The same question of the skill catalog: offered one line per skill, does the model pick the
    /// one this question calls for, load it, and coach in the same attempt? Two questions, because
    /// picking the right one out of three is the part a unit test cannot answer.
    @Test func theModelLoadsTheSkillTheQuestionCallsFor() async throws {
        let providers = Self.requestedProviders()
        guard !providers.isEmpty else { return }
        let capabilities = CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: false, skills: SkillCatalog.bundled())
        for provider in providers {
            let directory = try liveDirectory(provider)
            let traffic = FileSessionAudit(directory: directory)
            var loaded: [String: String] = [:]
            for (question, expected) in [(Self.behavioralQuestion, "behavioral"),
                                         (Self.designQuestion, "system-design")] {
                guard let coached = try await coach(provider, capabilities: capabilities,
                                                    asking: question, directory: directory,
                                                    traffic: traffic) else { break }
                #expect(coached.outcome == .spoke)
                let names = coached.activity.events.compactMap { event -> String? in
                    guard case .capabilityLoaded(let kind, let name) = event, kind == .skill
                    else { return nil }
                    return name
                }
                #expect(names == [expected])
                loaded[expected] = "\(names.joined(separator: ",")) in \(coached.milliseconds)ms"
            }
            _ = await traffic.close()
            print("""
                JARVIS_LIVE_CAPABILITY provider=\(provider.rawValue) \
                behavioral=\(loaded["behavioral"] ?? "(none)") \
                system_design=\(loaded["system-design"] ?? "(none)")
                """)
        }
    }

    /// Nothing runs unless the environment asks for it by provider; an unknown value is a mistake
    /// worth reporting rather than a silent no-op.
    private static func requestedProviders() -> [BrainProvider] {
        guard let requested = ProcessInfo.processInfo
            .environment["JARVIS_LIVE_CAPABILITY_PROVIDER"] else { return [] }
        switch requested {
        case "all": return [.openAI, .claudeCode, .codexCLI]
        case BrainProvider.openAI.rawValue: return [.openAI]
        case BrainProvider.claudeCode.rawValue: return [.claudeCode]
        case BrainProvider.codexCLI.rawValue: return [.codexCLI]
        default:
            Issue.record("unknown JARVIS_LIVE_CAPABILITY_PROVIDER value: \(requested)")
            return []
        }
    }

    private func verify(_ provider: BrainProvider) async throws {
        let catalogued = CoachCapabilities.compose(disabledTools: [], prepSourcesConfigured: true)
        let directory = try liveDirectory(provider)
        let traffic = FileSessionAudit(directory: directory)
        // Each run gets its own client: a CLI target bakes the prompt for the capabilities it was
        // built with, so the two shapes cannot share one warmed process. The bare run is the same
        // question with nothing to load, so the difference is what a load costs the user in the
        // only unit that matters.
        guard let loaded = try await coach(provider, capabilities: catalogued,
                                           asking: Self.explicitQuestion,
                                           directory: directory, traffic: traffic),
              let implied = try await coach(provider, capabilities: catalogued,
                                            asking: Self.implicitQuestion,
                                            directory: directory, traffic: traffic),
              let bare = try await coach(provider, capabilities: .default,
                                         asking: Self.explicitQuestion,
                                         directory: directory, traffic: traffic)
        else {
            _ = await traffic.close()
            return
        }
        // `record` only enqueues on the shared audit worker, so the traffic file is complete only
        // once close has drained it. Read it after that, never alongside it.
        _ = await traffic.close()

        let kinds = loaded.activity.kinds
        #expect(loaded.outcome == .spoke)
        #expect(kinds.contains(.capabilityLoaded))
        #expect(kinds.contains(.prepNotesSearched))
        if let load = kinds.firstIndex(of: .capabilityLoaded),
           let search = kinds.firstIndex(of: .prepNotesSearched) {
            #expect(load < search)
        }
        try checkOffers(in: directory, provider: provider)

        print("""
            JARVIS_LIVE_CAPABILITY provider=\(provider.rawValue) \
            with_notes_ms=\(loaded.milliseconds) without_notes_ms=\(bare.milliseconds) \
            actions=\(kinds.map(\.rawValue).joined(separator: ">")) \
            implicit_cue_loaded=\(implied.activity.kinds.contains(.capabilityLoaded)) \
            implicit_cue_ms=\(implied.milliseconds) \
            tip=\(loaded.overlay.rendered.last?.joined(separator: " | ") ?? "(none)") \
            traffic=\(directory.appendingPathComponent(FileSessionAudit.brainTrafficFilename).path)
            """)
    }

    /// What each request offered, read back from the session's own traffic log. The two paths
    /// express an offer differently, so they are checked differently: the API path declares an array
    /// per request and a deferred tool must appear only after the load, while a CLI path bakes one
    /// instruction block at startup that lists the hot schemas and names the rest in the catalog —
    /// there the contract is that the block never changes and never advertises a deferred schema.
    private func checkOffers(in directory: URL, provider: BrainProvider) throws {
        let rows = try String(
            contentsOf: directory.appendingPathComponent(FileSessionAudit.brainTrafficFilename),
            encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            .compactMap { $0["request"] as? [String: Any] }
        guard provider.usesLocalCLI else {
            let declared = rows.compactMap { request -> Set<String>? in
                guard let tools = request["tools"] as? [[String: Any]] else { return nil }
                return Set(tools.compactMap { $0["name"] as? String })
            }
            #expect(declared.first?.contains(CoachCapabilities.loadToolName) == true)
            #expect(declared.first?.contains(searchPrepNotesTool.name) == false)
            #expect(declared.dropFirst().contains { $0.contains(searchPrepNotesTool.name) })
            return
        }
        let catalogued = rows.compactMap { $0["instructions"] as? String }
            .filter { $0.contains(searchPrepNotesTool.description) }
        #expect(!catalogued.isEmpty)
        #expect(Set(catalogued).count == 1, "a CLI target's instructions must never change")
        #expect(catalogued.first?.contains("- \(searchPrepNotesTool.name) — ") == false)
        #expect(catalogued.first?.contains(searchPrepNotesTool.parametersJSON) == false)
    }

    private struct Coached {
        let outcome: TurnOutcome
        let activity: RecordingActivity
        let overlay: FakeOverlay
        let milliseconds: Int
    }

    private func coach(
        _ provider: BrainProvider, capabilities: CoachCapabilities, asking question: String,
        directory: URL, traffic: FileSessionAudit
    ) async throws -> Coached? {
        guard let client = try makeClient(
            provider, capabilities: capabilities, directory: directory, traffic: traffic)
        else { return nil }
        defer { client.terminate() }
        let transcript = RollingTranscript()
        let activity = RecordingActivity()
        let overlay = FakeOverlay()
        let target = BrainTarget(
            provider: provider, modelID: BrainModelCatalog.defaultModel(for: provider).id)
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [.init(target: target, brain: client)]),
            screen: FakeScreen(), overlay: overlay, clock: ManualClock(now: 100),
            automaticAttemptDelay: { _ in },
            activity: activity,
            capabilities: capabilities,
            prepMaterial: Self.notes)
        transcript.append(.init(speaker: .me, text: question, at: 100))

        let started = ContinuousClock.now
        let outcome = await driver.handleTrigger(.turnEnd)
        let elapsed = started.duration(to: .now).components
        return Coached(
            outcome: outcome, activity: activity, overlay: overlay,
            milliseconds: Int(elapsed.seconds * 1_000)
                + Int(elapsed.attoseconds / 1_000_000_000_000_000))
    }

    /// The real client for this provider, or nil when the machine cannot reach it — a missing CLI or
    /// key is a skipped arm, not a failed assertion about this change.
    private func makeClient(
        _ provider: BrainProvider, capabilities: CoachCapabilities,
        directory: URL, traffic: FileSessionAudit
    ) throws -> BrainClient? {
        let model = BrainModelCatalog.defaultModel(for: provider).id
        guard provider.usesLocalCLI else {
            guard let key = FileSecretStore().apiKey(for: .openAIAPIKey), !key.isEmpty else {
                Issue.record("no stored OpenAI key; skipping the openai arm")
                return nil
            }
            return OpenAIBrainClient(
                apiKey: key, model: model,
                reasoningEffort: ReasoningEffort.low.rawValue,
                timeout: BrainWorkloadTimeout.liveCoaching,
                maxOutputTokens: ReasoningEffort.low.maxOutputTokens,
                traffic: traffic, trafficTag: "coach")
        }
        guard let detected = AgentCLIDetector().detect(provider),
              detected.authenticationStatus != .signedOut else {
            Issue.record("\(provider.displayName) is missing or signed out; skipping that arm")
            return nil
        }
        return CLIBrainClient(
            provider: provider, executable: detected.executableURL, model: model,
            reasoningEffort: ReasoningEffort.low.rawValue,
            workDirectory: directory, timeout: BrainWorkloadTimeout.liveCoaching,
            traffic: traffic, trafficTag: "coach",
            systemPrompt: JarvisPrompts.Coach.system(capabilities: capabilities),
            tools: capabilities.tools,
            toolChoice: .required,
            runtime: CLIBrainRuntime(
                provider: provider, codexSupportedFeatures: detected.supportedFeatures),
            prewarm: true)
    }

    /// What each coach request actually offered the model, read back from the session's own traffic
    /// log: the declared `tools` on the API path, and the one baked `instructions` block on a CLI
    /// path, where a tool is "offered" by being named in the protocol the process was warmed with.
    private func declaredToolNames(in directory: URL, provider: BrainProvider) throws -> [Set<String>] {
        let url = directory.appendingPathComponent(FileSessionAudit.brainTrafficFilename)
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        return lines.compactMap { line -> Set<String>? in
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8)))
                    as? [String: Any],
                  let request = row["request"] as? [String: Any] else { return nil }
            if let tools = request["tools"] as? [[String: Any]] {
                return Set(tools.compactMap { $0["name"] as? String })
            }
            guard let instructions = request["instructions"] as? String else { return nil }
            // The CLI protocol lists a callable tool as "- <name> — "; a catalogued one appears
            // only as "- <name>: " inside the system text, which is not an offer to call it.
            return Set(CoachCapabilities
                .compose(disabledTools: [], prepSourcesConfigured: true).tools
                .map(\.name)
                .filter { instructions.contains("- \($0) — ") })
        }
    }

    private func liveDirectory(_ provider: BrainProvider) throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".jarvis", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent(
            "capability-live-\(provider.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return directory
    }
}
