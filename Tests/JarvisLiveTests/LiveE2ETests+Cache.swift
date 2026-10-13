import Foundation
import JarvisBrainProviders
import JarvisCore
import Testing

extension LiveE2ETests {
    private struct CacheTraffic {
        let attemptID: Int?
        let phase: String?
        let contextRevision: UInt?
        let status: Int?
        let error: String?
        let provider: String?
        let kind: String?
        let exchange: RecordedExchange
        let cache: [String: Any]
    }

    @Test func scenarioCACHE() async throws {
        guard let launcher = await LiveE2ELauncher.begin(scenario: LiveE2ECacheCheck.scenarioID) else { return }
        let launch = try await launcher.launch()
        var results = LiveE2EResults(scenario: LiveE2ECacheCheck.scenarioID)
        guard let evidence = Self.requireEvidence(launch, &results) else {
            try launcher.finish(results)
            return
        }
        let says = launch.stepIndices(Self.isSay)
        let attempts = says.compactMap { launch.attempt(forStep: $0) }
        let traffic = try Self.cacheTraffic(in: #require(launch.sessionDirectory))
        let initial = traffic.filter { $0.phase == "initial" }
        results.check("CACHE", [
            (says.count == 8 && attempts.count == 8, "eight spoken steps mapped to fresh attempts"),
            (Set(attempts.map(\.id)).count == 8, "each spoken step has a distinct attempt"),
            (attempts.allSatisfy { $0.outcome == "spoke" && $0.terminal == "speak" },
             "every selected attempt completed and committed a spoken answer"),
            (attempts.allSatisfy { $0.provider == BrainProvider.openAI.rawValue
                && $0.model == LiveE2ECacheCheck.modelID }, "the fixed paid OpenAI target served every attempt"),
            (!evidence.attempts.contains { $0.wake == "pending_work" }, "no failed work was retried"),
            (initial.count == 8 && Set(initial.compactMap(\.attemptID)) == Set(attempts.map(\.id)),
             "exactly one initial provider request per selected attempt, with no extra initial requests"),
            (!traffic.isEmpty && traffic.count <= LiveE2ECacheBudget.maximumRequests,
             "provider calls stayed within the request cap"),
            (traffic.allSatisfy { $0.status == 200 && $0.error == nil && $0.kind == "provider_call"
                && $0.provider == BrainProvider.openAI.rawValue && $0.exchange.model == LiveE2ECacheCheck.modelID },
             "all coaching calls succeeded on the fixed paid target"),
            (evidence.traffic.allSatisfy { $0.tag == "coach" }, "the steady run had no compaction requests"),
            (evidence.malformedRecordCount == 0, "the session evidence has no malformed records"),
        ])
        let warmupIDs = Set(attempts.prefix(LiveE2ECacheCheck.warmupAttempts).map(\.id))
        let calls = traffic.flatMap { record in
            record.exchange.outputs.compactMap { output -> (Int?, RecordedExchange.Call)? in
                guard case .call(let call) = output else { return nil }
                return (record.attemptID, call)
            }
        }
        let skillLoads = calls.filter { $0.1.name == "load_skill" }
        let toolLoads = calls.filter { $0.1.name == "load_tool" }
        let warmupPhases = Set(traffic.filter { warmupIDs.contains($0.attemptID ?? -1) }.compactMap(\.phase))
        results.check("CACHE-guidance", [
            (skillLoads.count == 1 && warmupIDs.contains(skillLoads.first?.0 ?? -1),
             "the retained coaching skill loaded once during warm-up"),
            (toolLoads.count == 1 && warmupIDs.contains(toolLoads.first?.0 ?? -1),
             "the preparation tool loaded once during warm-up"),
            (warmupPhases.contains("load_skill_continuation")
                && warmupPhases.contains("load_tool_continuation")
                && warmupPhases.contains("search_prep_notes_continuation"),
             "real skill, tool and prep-search continuations preceded the measured window"),
            (evidence.activity.contains { $0.kind == "prepNotesSearched" }, "preparation retrieval ran"),
            (!evidence.activity.contains { $0.kind == "prepNotesUnavailable" },
             "the preparation index was ready when retrieval ran"),
            (!evidence.activity.contains { $0.kind == "screenViewed" }, "spoken questions needed no screen capture"),
            (evidence.activity.contains { $0.loadedCapability?.name == LiveE2ECacheFixture.skillName },
             "the synthetic skill loaded successfully"),
            (evidence.activity.contains { $0.loadedCapability?.name == "search_prep_notes" },
             "the preparation-search tool loaded successfully"),
            (traffic.contains { record in record.exchange.input.contains { item in
                guard case .result(_, let output) = item else { return false }
                return output?.contains(LiveE2ECacheFixture.skill.body) == true
            } }, "the full retained skill body reached the actual provider request"),
            (traffic.contains { record in record.exchange.input.contains { item in
                guard case .result(_, let output) = item else { return false }
                return output?.contains("Do not treat acceptance as evidence that a downstream charge completed") == true
            } }, "the actual preparation-search result reached the provider"),
        ])
        for (index, attempt) in attempts.enumerated() {
            let hints = evidence.rows(in: attempt).filter { $0.kind == "tip" }.compactMap { $0.response?.hint }
            results.check("CACHE-guidance", hints.count == 1 && hints[0].isEmpty == false,
                          "attempt \(attempt.id) delivered one nonempty final hint")
            results.check("CACHE-guidance", hints.allSatisfy { !Self.carriesProtocolText($0) },
                          "attempt \(attempt.id) delivered coaching without protocol text")
            if index >= LiveE2ECacheCheck.warmupAttempts {
                results.check("CACHE-guidance", hints.first?.lowercased().contains("replay key") == true,
                              "attempt \(attempt.id) applied the retained reference's replay key guidance")
            }
        }
        var samples: [LiveE2ECacheCheck.Sample] = []
        for attempt in attempts {
            let selected = initial.filter { $0.attemptID == attempt.id }
            guard selected.count == 1, let record = selected.first else { continue }
            let measured = samples.count >= LiveE2ECacheCheck.warmupAttempts
            if measured {
                results.check("CACHE-prefix", [
                    (record.cache["scope"] as? String == "client_wire", "cache audit describes the actual client wire"),
                    (record.cache["request_prefix_preserved"] as? Bool == true,
                     "attempt \(attempt.id) preserved the preceding initial request prefix"),
                    (record.cache["input_comparison_truncated"] as? Bool == false,
                     "attempt \(attempt.id) has complete input-prefix evidence"),
                ])
            }
            samples.append(.init(
                attemptID: attempt.id, totalInput: record.exchange.usage?.totalInput,
                cacheRead: record.exchange.usage?.cacheRead,
                instructionsFingerprint: record.exchange.instructions ?? "",
                toolsFingerprint: record.exchange.toolsFingerprint,
                settingsFingerprint: record.cache["settings_sha256"] as? String ?? "",
                contextRevision: record.contextRevision,
                inputFingerprints: record.exchange.inputFingerprints))
        }
        let check = LiveE2ECacheCheck.evaluate(samples)
        results.check("CACHE-hit", check.passed, check.failures.joined(separator: "; "))
        let rate = check.weightedReadRate.map { String(format: "%.1f%%", $0 * 100) } ?? "unknown"
        results.note("CACHE-hit", "\(check.historyHits)/6 history hits; weighted initial cache reads \(rate); two warm-ups excluded")
        Self.recordCacheUsage(traffic, warmupIDs: warmupIDs, &results)
        Self.checkCleanEnd(launch, evidence, endedByUser: true, &results)
        try launcher.finish(results)
    }

    private static func cacheTraffic(in directory: URL) throws -> [CacheTraffic] {
        let text = try String(contentsOf: directory.appendingPathComponent(FileSessionAudit.brainTrafficFilename),
                              encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).compactMap { line in
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            guard object["tag"] as? String == "coach" else { return nil }
            let context = object["coach_attempt"] as? [String: Any] ?? [:]
            return CacheTraffic(
                attemptID: context["id"] as? Int, phase: context["phase"] as? String,
                contextRevision: (context["context_revision"] as? NSNumber)?.uintValue,
                status: object["status"] as? Int, error: object["error"] as? String,
                provider: object["provider"] as? String, kind: object["record_kind"] as? String,
                exchange: RecordedExchange.read(request: object["request"], response: object["response"]),
                cache: object["cache"] as? [String: Any] ?? [:])
        }
    }

    private static func recordCacheUsage(
        _ traffic: [CacheTraffic], warmupIDs: Set<Int>, _ results: inout LiveE2EResults
    ) {
        func count(_ value: Int?) -> String { value.map(String.init) ?? "unknown" }
        for record in traffic {
            let usage = record.exchange.usage
            let window = warmupIDs.contains(record.attemptID ?? -1) ? "warm-up" : "measured"
            var cost = "unknown"
            if let read = usage?.cacheRead, let write = usage?.cacheWrite,
               let uncached = usage?.uncachedInput, let output = usage?.output,
               read >= 0, write >= 0, uncached >= 0, output >= 0 {
                let dollars = (Double(uncached) * 2 + Double(read) * 0.1
                    + Double(write) * 2.5 + Double(output) * 10) / 1_000_000
                cost = String(format: "$%.6f", dollars)
            }
            results.note("CACHE-usage", "\(window) attempt \(count(record.attemptID)) \(record.phase ?? "unknown phase"): "
                + "total input \(count(usage?.totalInput)), cache read \(count(usage?.cacheRead)), "
                + "cache write \(count(usage?.cacheWrite)), uncached input \(count(usage?.uncachedInput)), "
                + "output \(count(usage?.output)); estimated coaching cost \(cost)")
        }
    }
}
