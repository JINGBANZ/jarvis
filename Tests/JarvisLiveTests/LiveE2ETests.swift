import Foundation
import JarvisCore
import JarvisEvaluation
import Testing

/// The live e2e cases, asserted on what each scenario's session left behind.
///
/// Steps live in `Scenarios/*.json`; the case index and the reasoning live in
/// wiki/live-e2e-tests.md. Every assertion is an order or a count, never a wording or a duration,
/// because model phrasing and provider latency vary between runs. Where the outcome is the model's
/// choice, the case records a note instead of asserting.
@Suite(.serialized)
struct LiveE2ETests {
    typealias Evidence = LiveSessionEvidence
    typealias Attempt = LiveSessionEvidence.Attempt
    typealias Row = LiveSessionEvidence.ActivityRow

    // The short scenarios run first: a missing grant, key, or login shows within minutes.

    @Test func scenarioR() async throws {
        guard let launcher = await LiveE2ELauncher.begin(scenario: "R") else { return }
        let launch = try await launcher.launch()
        var results = LiveE2EResults(scenario: "R")
        if let evidence = Self.requireEvidence(launch, &results) {
            let ready = evidence.debugLines.firstIndex {
                $0.contains("coaching ready (mic + system audio)")
            }
            let microphone = evidence.debugLines.firstIndex {
                $0.contains("capture readiness [microphone]")
            }
            let system = evidence.debugLines.firstIndex { $0.contains("capture readiness [system]") }
            results.check("G01", [
                (ready != nil, "R logged coaching ready (mic + system audio)"),
                (Self.precedes(microphone, ready), "microphone frames arrived before ready"),
                (Self.precedes(system, ready), "system frames arrived before ready"),
            ])
            Self.checkCleanEnd(launch, evidence, endedByUser: true, &results)
        }
        try launcher.finish(results)
    }

    @Test func scenarioF02() async throws {
        guard let launcher = await LiveE2ELauncher.begin(scenario: "F02") else { return }
        let launch = try await launcher.launch(secretsDirectory: try launcher.makeInvalidKeyDirectory())
        var results = LiveE2EResults(scenario: "F02")
        if let evidence = Self.requireEvidence(launch, &results) {
            let ended = evidence.activity.first { $0.kind == "sessionEnded" }
            let startedAt = launch.sessionDirectory.flatMap(Self.creationTime(of:))
            let elapsed = ended?.occurredAt.flatMap { end in startedAt.map { end - $0 } }
            results.check("F02", [
                (ended != nil, "the session ended"),
                (ended?.message.contains("invalid_api_key") == true,
                 "the end names invalid_api_key (saw \(ended?.message ?? "no end row"))"),
                (!evidence.activity.contains { $0.kind == "systemAudioStopped" },
                 "no system-audio degradation row"),
            ])
            results.time("start-to-end", seconds: elapsed)
            Self.checkCleanEnd(launch, evidence, endedByUser: false, &results)
        }
        try launcher.finish(results)
    }

    @Test func scenarioF01System() async throws {
        guard let launcher = await LiveE2ELauncher.begin(scenario: "F01-system") else { return }
        let launch = try await launcher.launch()
        var results = LiveE2EResults(scenario: "F01-system")
        if let evidence = Self.requireEvidence(launch, &results) {
            results.check("F01", [
                (evidence.activity.contains { $0.kind == "systemAudioStopped" },
                 "missing system frames degrade with the system-audio row"),
                (!evidence.debugLines(containing: "coaching ready (microphone only)").isEmpty,
                 "coaching ready (microphone only) logged"),
                (evidence.debugLines(containing: "coaching ready (mic + system audio)").isEmpty,
                 "full readiness never claimed"),
            ])
            Self.checkCleanEnd(launch, evidence, endedByUser: true, &results)
        }
        try launcher.finish(results)
    }

    @Test func scenarioF01Microphone() async throws {
        guard let launcher = await LiveE2ELauncher.begin(scenario: "F01-microphone") else { return }
        let launch = try await launcher.launch()
        var results = LiveE2EResults(scenario: "F01-microphone")
        if let evidence = Self.requireEvidence(launch, &results) {
            let ended = evidence.activity.last { $0.kind == "sessionEnded" }
            results.check("F01", [
                (ended != nil, "missing microphone frames end the session"),
                (ended?.message.contains("microphone") == true,
                 "the end names the microphone capture error (saw \(ended?.message ?? "no end row"))"),
                (evidence.debugLines(containing: "coaching ready").isEmpty, "readiness never claimed"),
            ])
            Self.checkCleanEnd(launch, evidence, endedByUser: false, &results)
        }
        try launcher.finish(results)
    }

    @Test func scenarioF04() async throws {
        guard let launcher = await LiveE2ELauncher.begin(scenario: "F04") else { return }
        let launch = try await launcher.launch(claudeCLI: try launcher.makeClaudeStub())
        var results = LiveE2EResults(scenario: "F04")
        if let evidence = Self.requireEvidence(launch, &results) {
            let says = launch.stepIndices(Self.isSay)
            let restored = says.count == 4 ? launch.attempt(forStep: says[3]) : nil
            // Each question before the restore is its own cycle: its turn-end attempt, then
            // pending-work retries on the one target until the failure budget exhausts the cycle
            // (three, `BrainRouteSession.failuresPerTarget`; wiki/architecture.md#ordered-provider-route).
            let cycleStarts = says.prefix(3).compactMap { launch.attempt(forStep: $0) }
            let cycles = cycleStarts.enumerated().map { index, first in
                let end = index + 1 < cycleStarts.count
                    ? cycleStarts[index + 1].id : (restored?.id ?? Int.max)
                return evidence.attempts.filter { $0.id >= first.id && $0.id < end }
            }
            let cycleRows = evidence.activity.filter { $0.kind == "coachingTurnFailed" }
            // A cycle's row lands after its last failed attempt and before the next question's
            // attempt, so no request is made in between.
            let rowsBetweenCycles = !cycles.isEmpty && cycles.indices.allSatisfy { index in
                guard index < cycleRows.count,
                      let row = cycleRows[index].occurredAt?.rounded(.down),
                      let lastFinished = cycles[index].last?.finishedAt,
                      let nextStarted = (index + 1 < cycles.count
                          ? cycles[index + 1].first : restored)?.startedAt else { return false }
                return row >= lastFinished && row <= nextStarted
            }
            let restoredTip = restored.map { attempt in
                evidence.rows(in: attempt).contains { $0.kind == "tip" }
            } ?? false
            results.check("F04", [
                (cycles.count == 3 && cycles.allSatisfy { cycle in
                    cycle.count == 3
                        && cycle.allSatisfy { $0.outcome == "brain_error" }
                        && cycle.dropFirst().allSatisfy { $0.trigger == "pending_work" }
                }, "each question fails three attempts on its own budget (saw \(cycles.map(\.count)))"),
                (cycleRows.count == cycles.count,
                 "one coaching-failed row per failed cycle (saw \(cycleRows.count))"),
                (rowsBetweenCycles, "no attempt between a failed cycle and the next question"),
                (restored?.provider == "claude-code" && restored?.outcome == "spoke" && restoredTip,
                 "the question after the restore gets a tip on Claude Code (saw "
                    + "\(restored?.provider ?? "no attempt") \(restored?.outcome ?? ""))"),
                (evidence.activity.filter { $0.kind == "sessionEnded" }.count == 1,
                 "no session end before Stop"),
            ])
            Self.checkCleanEnd(launch, evidence, endedByUser: true, &results)
        }
        try launcher.finish(results)
    }

    @Test func scenarioB() async throws {
        guard let launcher = await LiveE2ELauncher.begin(scenario: "B") else { return }
        let launch = try await launcher.launch()
        var results = LiveE2EResults(scenario: "B")
        if let evidence = Self.requireEvidence(launch, &results) {
            let b1 = launch.attemptChain(forStep: launch.stepIndices(Self.isPress).first)
            let b2 = launch.attemptChain(forStep: launch.stepIndices(Self.isSay).first)
            Self.noteStalls([("B1", b1), ("B2", b2)], evidence, &results)
            let b1Rows = evidence.rows(inChain: b1)
            let b1Loads = b1Rows.compactMap { $0.loadedCapability?.name }
            let b1Screens = b1Rows.filter { $0.kind == "screenViewed" }.count
            let b1Tip = b1Rows.contains { $0.kind == "tip" }
            // The discriminating Codex press #318 asked for: whether Codex loads on a press with a
            // real screenshot is recorded, not required.
            let b1Summary = "B1 on Codex: \(b1Screens) screen view(s), loads \(b1Loads), "
                + (b1Tip ? "a tip" : "no tip")
            results.note("C01", b1Summary)
            results.note("C09", b1Summary)
            results.note("C17", b1Summary)
            results.time("B1 press-to-tip", seconds: Self.pressToTip(evidence, b1))

            let codex = evidence.traffic.filter { $0.tag == "coach" && $0.cliProvider == "codex-cli" }
            results.check("C16", [
                (!evidence.activity.contains {
                    ["behavioral", "system-design"].contains($0.loadedCapability?.name ?? "")
                }, "switched-off skills never load"),
                (!evidence.activity.contains { $0.kind == "prepNotesSearched" }, "no prep search"),
                (!b2.isEmpty, "B2 ran an attempt"),
            ])
            results.note("C16", "B2 ended \(b2.last?.terminal ?? "without an attempt"), diagram "
                + Self.describe(Self.diagram(evidence, b2.last)))
            results.check("C18", [
                (!codex.isEmpty, "Codex coach requests were recorded"),
                (codex.allSatisfy { !($0.instructions ?? "").contains("search_prep_notes") },
                 "instructions never name search_prep_notes"),
                (codex.allSatisfy { !($0.instructions ?? "").contains("Tools you can load") },
                 "instructions carry no tools catalog or load-tool clause"),
            ])
            let catalogs = Set(codex.map { Self.skillCatalog(in: $0.instructions ?? "") })
            results.check("C19", catalogs == [["coding"]],
                          "the skills catalog lists only coding (saw \(catalogs.sorted { $0.count < $1.count }))")
            Self.noteTextProtocol(evidence, &results)
            Self.checkCleanEnd(launch, evidence, endedByUser: true, &results)
        }
        try launcher.finish(results)
    }

    @Test func scenarioA() async throws {
        guard let launcher = await LiveE2ELauncher.begin(scenario: "A") else { return }
        let launch = try await launcher.launch()
        var results = LiveE2EResults(scenario: "A")
        guard let evidence = Self.requireEvidence(launch, &results) else {
            try launcher.finish(results)
            return
        }
        let presses = launch.stepIndices(Self.isPress)
        let says = launch.stepIndices(Self.isSay)
        guard presses.count == 3, says.count == 7 else {
            results.check("A", false, "A has 3 presses and 7 spoken steps (saw \(presses.count), \(says.count))")
            try launcher.finish(results)
            return
        }
        // Each step is its attempt chain: the attempt it started plus any retries a provider stall
        // caused. Rows come from the whole chain, and the last attempt is the one that answered.
        let a1 = launch.attemptChain(forStep: presses[0])
        let a7 = [launch.attemptChain(forStep: presses[1]), launch.attemptChain(forStep: presses[2])]
        let a2 = launch.attemptChain(forStep: says[0])
        let a3 = launch.attemptChain(forStep: says[1])
        let a4 = launch.attemptChain(forStep: says[2])
        let a5 = launch.attemptChain(forStep: says[3])
        let a6 = launch.attemptChain(forStep: says[4])
        let a8 = launch.attemptChain(forStep: says[5])
        let a9 = launch.attemptChain(forStep: says[6])
        Self.noteStalls(
            [("A1", a1), ("A2", a2), ("A3", a3), ("A4", a4), ("A5", a5), ("A6", a6),
             ("A7", a7[0]), ("A7", a7[1]), ("A8", a8), ("A9", a9)],
            evidence, &results)

        func rows(_ chain: [Attempt]) -> [Row] { evidence.rows(inChain: chain) }
        func loads(_ chain: [Attempt]) -> [String] { rows(chain).compactMap { $0.loadedCapability?.name } }
        func count(_ kind: String, in chain: [Attempt]) -> Int { rows(chain).filter { $0.kind == kind }.count }
        func tip(_ chain: [Attempt]) -> Row? { rows(chain).last { $0.kind == "tip" } }
        /// The rows a case reasons about, in order: loads by name, searches, screen views, endings.
        func sequence(_ chain: [Attempt]) -> [String] {
            rows(chain).compactMap { row -> String? in
                switch row.kind {
                case "capabilityLoaded": return row.loadedCapability.map { "load \($0.name)" }
                case "prepNotesSearched": return "search"
                case "screenViewed": return "screen"
                case "tip": return "tip"
                case "stayedSilent": return "silent"
                default: return nil
                }
            }
        }

        // C01: a press loads what its screen needs and still ends in one clean tip.
        func pressChecks(_ chain: [Attempt], _ label: String) -> [LiveE2EResults.Check] {
            let loadRows = rows(chain).filter { $0.kind == "capabilityLoaded" }
            let tipRow = tip(chain)
            return [
                (!chain.isEmpty, "\(label) ran an attempt"),
                (count("screenViewed", in: chain) == 1,
                 "\(label) viewed the screen once (saw \(count("screenViewed", in: chain)))"),
                (loadRows.count == 1, "\(label) loaded one capability (saw \(loads(chain)))"),
                (Self.precedes(loadRows.first?.index, tipRow?.index), "\(label) loaded before its tip"),
                (tipRow.map { !Self.carriesProtocolText($0.message) } ?? false,
                 "\(label) tip carries no protocol text"),
            ]
        }
        results.check("C01", pressChecks(a1, "A1"))
        results.time("A1 press-to-tip", seconds: Self.pressToTip(evidence, a1))
        results.time("A7 first press-to-tip", seconds: Self.pressToTip(evidence, a7[0]))
        results.time("A7 second press-to-tip", seconds: Self.pressToTip(evidence, a7[1]))

        let a2Summary = "A2 ended \(a2.last?.terminal ?? "without an attempt"), loads \(loads(a2))"
        results.note("C02", a2Summary)
        results.note("G05", a2Summary)
        results.note("C03", "A3 loaded \(loads(a3))")

        let committed = evidence.committedLoads.map(\.name)
        results.check("C04", [
            (Set(committed).count == committed.count, "committed loads are unique (saw \(committed))"),
            (evidence.debugLines(containing: "was already loaded").isEmpty, "no already-loaded line"),
        ])

        let a3Sequence = sequence(a3)
        let a4Sequence = sequence(a4)
        let firstOpenAI = a4.flatMap { evidence.traffic(for: $0) }.first { $0.cliProvider == nil }
        results.check("C05", [
            (Self.precedes(a3Sequence.firstIndex(of: "load search_prep_notes"),
                           a3Sequence.firstIndex(of: "search")),
             "A3 loads search_prep_notes before searching (saw \(a3Sequence))"),
            (firstOpenAI?.declaredToolNames.contains("search_prep_notes") == true,
             "A4's first OpenAI request declares search_prep_notes"),
        ])
        results.check("C06", Self.precedes(a3Sequence.firstIndex(of: "load behavioral"),
                                           a3Sequence.lastIndex(of: "tip")),
                      "A3 loads behavioral before its tip (saw \(a3Sequence))")
        results.check("C07", [
            (a3Sequence == ["load behavioral", "load search_prep_notes", "search", "tip"],
             "A3's chain stays in one attempt (saw \(a3Sequence))"),
            (a4Sequence == ["load system-design", "tip"],
             "A4's chain stays in one attempt (saw \(a4Sequence))"),
            (evidence.debugLines(containing: "tool loop exhausted").isEmpty, "no tool loop exhausted"),
        ])
        results.time("A3 question-to-tip", seconds: Self.questionToTip(evidence, a3))
        results.time("A4 question-to-tip", seconds: Self.questionToTip(evidence, a4))

        results.check("C08", [
            (sequence(a5).contains("search"), "A5 searched prep notes (saw \(sequence(a5)))"),
            (loads(a5).isEmpty, "A5 loaded nothing"),
            (a5.contains { evidence.traffic(for: $0).contains { $0.cliProvider == "codex-cli" } },
             "A5 ran on Codex"),
        ])
        results.time("A5 question-to-tip", seconds: Self.questionToTip(evidence, a5))
        results.check("C09", loads(a1).contains("coding"), "A1 loaded coding (saw \(loads(a1)))")
        results.check("C10", committed == ["coding", "behavioral", "search_prep_notes", "system-design"],
                      "four loads, each once, in order (saw \(committed))")

        results.check("C11", [
            (a7.allSatisfy { !$0.isEmpty }, "both A7 presses ran an attempt"),
            (loads(a7[0]).isEmpty && loads(a7[1]).isEmpty, "neither A7 press loads anything"),
        ])
        let requestsPerPress = a7.map { chain in chain.last.map { evidence.traffic(for: $0).count } ?? 0 }
        if requestsPerPress != [1, 1] {
            results.note("C11", "A7 requests per press: \(requestsPerPress)")
        }

        results.check("C12", Self.hasDiagram(evidence, a4.last),
                      "A4's speak call carries a diagram (saw \(Self.describe(Self.diagram(evidence, a4.last))))")
        results.note("C12", "A8 on Codex: \(Self.describe(Self.diagram(evidence, a8.last)))")
        let unexpectedDiagrams = [("A1", a1), ("A3", a3), ("A5", a5), ("A6", a6),
                                  ("A7", a7[0]), ("A7", a7[1]), ("A9", a9)]
            .filter { Self.hasDiagram(evidence, $0.1.last) }.map(\.0)
        results.note("C13", unexpectedDiagrams.isEmpty
            ? "no diagram outside the architecture stage" : "diagram at \(unexpectedDiagrams)")

        // C14: loaded state survives both switches. OpenAI replays the load pairs Claude Code minted.
        let loadsBeforeSwitch = a4.first.map { switchAttempt in
            evidence.attempts
                .filter { $0.id < switchAttempt.id && $0.isCommitted }
                .flatMap { evidence.rows(in: $0).compactMap(\.loadedCapability) }
        } ?? []
        let replayedCalls = firstOpenAI?.replayedFunctionCalls ?? []
        let replayedOutputs = Set(firstOpenAI?.replayedFunctionOutputCallIDs ?? [])
        let unreplayed = loadsBeforeSwitch.filter { load in
            !replayedCalls.contains { call in
                call.name == (load.kind == "skill" ? "load_skill" : "load_tool")
                    && call.arguments.contains(load.name)
                    && call.callID.hasPrefix("cli_")
                    && replayedOutputs.contains(call.callID)
            }
        }
        let codexInstructions = evidence.traffic
            .filter { $0.tag == "coach" && $0.cliProvider == "codex-cli" }
            .compactMap(\.instructions)
        results.check("C14", [
            (loadsBeforeSwitch.count == 3,
             "three loads committed before the OpenAI switch (saw \(loadsBeforeSwitch.map(\.name)))"),
            (!loadsBeforeSwitch.isEmpty && unreplayed.isEmpty,
             "A4 replays every earlier load pair with its cli_ call id (missing \(unreplayed.map(\.name)))"),
            (evidence.activity.filter { $0.kind == "brainChangeApplied" }.count >= 2,
             "both brain switches applied"),
            (!codexInstructions.isEmpty && Set(codexInstructions).count == 1,
             "Codex's baked instructions never change"),
        ])

        var c15: [LiveE2EResults.Check] = []
        for provider in ["claude-code", "codex-cli"] {
            let records = evidence.traffic.filter { $0.tag == "coach" && $0.cliProvider == provider }
            let later = Set(records.compactMap(\.attemptID))
                .subtracting([records.first?.attemptID].compactMap { $0 })
            c15.append((later.count >= 2,
                        "\(provider) coached at least two attempts after its first (saw \(later.count))"))
            c15.append((Set(records.compactMap(\.instructions)).count == 1,
                        "\(provider) instructions stay identical"))
        }
        c15.append((!evidence.traffic.contains {
            ($0.error ?? "").contains("instructions changed after runtime initialization")
        }, "no instructions-changed error"))
        results.check("C15", c15)
        Self.noteTextProtocol(evidence, &results)

        results.check("G01", [
            (evidence.activity.contains { $0.message.hasPrefix("🗣 heard (them)") }, "the them stream transcribed"),
            (evidence.activity.contains { $0.message.hasPrefix("🗣 heard (me)") }, "the me stream transcribed"),
        ])

        // G02: an earlier-started question stays ahead of a reply that finalized first. Activity rows
        // and attempt transcripts are stored in insertion order on purpose, and ConversationChronology
        // orders them by speech time for the viewer and the model. So the case needs a reply stored
        // before the question but spoken after it started, in both places. The reply is found by
        // speaker and time, never by wording: a one-word overlap is often mistranscribed.
        let questionRow = evidence.activity.last {
            $0.message.hasPrefix("🗣 heard (them)") && Self.normalized($0.message).contains("endpoint")
        }
        let invertedReplyRow = questionRow.flatMap { question in
            evidence.activity.first { row in
                guard let questionTime = question.occurredAt, let replyTime = row.occurredAt else {
                    return false
                }
                return row.message.hasPrefix("🗣 heard (me)") && row.index < question.index
                    && replyTime > questionTime
            }
        }
        let transcript = a8.last?.transcript ?? []
        let questionEntry = transcript.lastIndex {
            $0.speaker == "them" && Self.normalized($0.text).contains("endpoint")
        }
        let invertedReplyEntry = questionEntry.flatMap { questionIndex in
            transcript[..<questionIndex].first { entry in
                guard let questionTime = transcript[questionIndex].at, let replyTime = entry.at else {
                    return false
                }
                return entry.speaker == "me" && replyTime > questionTime
            }
        }
        results.check("G02", [
            (invertedReplyRow != nil,
             "Activity holds a reply stored before the question but spoken after it started"),
            (invertedReplyEntry != nil,
             "A8's transcript holds a reply stored before the question but spoken after it started (saw "
                + "\(transcript.map { "\($0.speaker)@\(Int(($0.at ?? -1).rounded()))s" }))"),
        ])
        results.check("G03", [
            (!a8.isEmpty && !a9.isEmpty, "A8 and A9 each ran an attempt"),
            ((a9.first?.id ?? Int.min) > (a8.last?.id ?? Int.max), "A9's attempt follows A8's"),
            (Self.precedes(a8.last?.finishedRecordIndex, a9.first?.startedRecordIndex),
             "A9 started only after A8 finished"),
        ])

        let screenViews = evidence.activity.filter { $0.kind == "screenViewed" }.count
        let textReads = evidence.debugLines(containing: "lines of on-screen text").count
        results.check("G04", [
            (count("screenViewed", in: a1) == 1, "A1 viewed the screen once"),
            (count("screenViewed", in: a6) == 1, "A6 viewed the screen once"),
            (count("screenViewed", in: a3) == 0, "A3 did not view the screen"),
            (count("screenViewed", in: a4) == 0, "A4 did not view the screen"),
            (count("screenViewed", in: a5) == 0, "A5 did not view the screen"),
            (screenViews > 0 && textReads == screenViews,
             "every screen view carried its recognized text (\(textReads) text reads for \(screenViews) views)"),
        ])
        let pressAttempts = [a1] + a7
        results.check("G06", [
            (evidence.activity.filter { $0.kind == "manualHint" }.count == 3, "three shortcut rows"),
            (pressAttempts.allSatisfy { count("screenViewed", in: $0) == 1 && tip($0) != nil },
             "each press viewed the screen once and ended in a tip"),
            (tip(a7[0]) != nil && tip(a7[0])?.message != tip(a7[1])?.message,
             "the second A7 hint differs from the first"),
            (tip(a1) != nil && tip(a1)?.message != tip(a7[0])?.message, "A7's first hint differs from A1's"),
        ])
        for line in evidence.debugLines(containing: "warm query ready")
            + evidence.debugLines(containing: "target thread ready") {
            results.timeDetail(line)
        }
        Self.checkCleanEnd(launch, evidence, endedByUser: true, &results)
        try launcher.finish(results)
    }

    // MARK: - Shared checks

    /// The scenario's own line: the app finished and left exactly one session.
    static func requireEvidence(_ launch: LiveE2ELaunch, _ results: inout LiveE2EResults) -> Evidence? {
        results.check(launch.scenario.id, [
            (launch.finished, "the app finished its scenario" + (launch.failure.map { ": \($0)" } ?? "")),
            (launch.sessionCount == 1, "exactly one session directory (saw \(launch.sessionCount))"),
        ])
        return launch.evidence
    }

    /// G08: the session ends last, its evidence seals, and no CLI child or Codex home outlives it.
    static func checkCleanEnd(
        _ launch: LiveE2ELaunch, _ evidence: Evidence, endedByUser: Bool,
        _ results: inout LiveE2EResults
    ) {
        let last = evidence.activity.last
        var checks: [LiveE2EResults.Check] = [
            (last?.kind == "sessionEnded", "the last Activity row is the session end (saw \(last?.kind ?? "no rows"))"),
            (evidence.healthState == "complete", "audit health is complete (saw \(evidence.healthState ?? "missing"))"),
            (launch.leftoverProcessIDs.isEmpty, "no CLI child survived (pids \(launch.leftoverProcessIDs))"),
            (launch.leftoverRuntimeHomes.isEmpty, "no Codex runtime home remained (\(launch.leftoverRuntimeHomes))"),
        ]
        if endedByUser {
            checks.append((last?.message.contains("session ended by user") == true, "the session ended by user"))
        }
        results.check("G08", checks)
    }

    /// C20: text-protocol fallbacks on the CLI brains are reported, never failed.
    static func noteTextProtocol(_ evidence: Evidence, _ results: inout LiveE2EResults) {
        let needles = ["was called before it was loaded", "nothing named", "no skill named",
                       "does not permit", "unknown or malformed"]
        let sightings = needles.compactMap { needle -> String? in
            let count = evidence.debugLines(containing: needle).count
            return count > 0 ? "\(count) x \"\(needle)\"" : nil
        }
        results.note("C20", sightings.isEmpty ? "no text-protocol fallback lines" : sightings.joined(separator: ", "))
    }

    /// A step whose provider stalled is judged through its retry (see `retryChain`); each stall is
    /// recorded so it stays visible beside the slower time it causes.
    static func noteStalls(
        _ steps: [(label: String, chain: [Attempt])], _ evidence: Evidence,
        _ results: inout LiveE2EResults
    ) {
        for (label, chain) in steps {
            let stalls = chain.filter(evidence.failedOnProviderStall)
            guard let first = stalls.first else { continue }
            let error = evidence.traffic(for: first).last { $0.error != nil }?.error ?? "no error recorded"
            let ending = chain.last?.isCommitted == true ? "the retry answered" : "no attempt answered"
            results.note(results.scenario, "\(label) stalled \(stalls.count)x on \(first.provider), \(ending): \(error)")
        }
    }

    static func pressToTip(_ evidence: Evidence, _ chain: [Attempt]) -> TimeInterval? {
        guard let tip = evidence.rows(inChain: chain).last(where: { $0.kind == "tip" }),
              let tipAt = tip.occurredAt,
              let press = evidence.activity.last(where: { $0.kind == "manualHint" && $0.index < tip.index }),
              let pressAt = press.occurredAt else { return nil }
        return tipAt - pressAt
    }

    static func questionToTip(_ evidence: Evidence, _ chain: [Attempt]) -> TimeInterval? {
        let rows = evidence.rows(inChain: chain)
        guard let first = rows.first, let tip = rows.last(where: { $0.kind == "tip" }),
              let tipAt = tip.occurredAt,
              let heard = evidence.activity.last(where: { $0.kind == "heard" && $0.index < first.index }),
              let heardAt = heard.occurredAt else { return nil }
        return tipAt - heardAt
    }

    static func diagram(_ evidence: Evidence, _ attempt: Attempt?) -> LiveSessionEvidence.SpeakDiagram {
        guard let attempt else { return .noSpeakCall }
        return evidence.traffic(for: attempt).last { $0.speakDiagram != .noSpeakCall }?.speakDiagram
            ?? .noSpeakCall
    }

    static func hasDiagram(_ evidence: Evidence, _ attempt: Attempt?) -> Bool {
        if case .present = diagram(evidence, attempt) { return true }
        return false
    }

    static func describe(_ diagram: LiveSessionEvidence.SpeakDiagram) -> String {
        switch diagram {
        case .noSpeakCall: "no speak call"
        case .none: "none"
        case .present: "present"
        }
    }

    /// Skill names listed under the catalog heading of a baked system prompt.
    static func skillCatalog(in instructions: String) -> [String] {
        guard let heading = instructions.range(of: "# Skills you can load") else { return [] }
        var names: [String] = []
        for line in instructions[heading.upperBound...].split(separator: "\n") {
            if line.hasPrefix("- "), let colon = line.firstIndex(of: ":") {
                names.append(String(line[line.index(line.startIndex, offsetBy: 2)..<colon]))
            } else if !names.isEmpty {
                break
            }
        }
        return names
    }

    static func creationTime(of directory: URL) -> TimeInterval? {
        (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate)?
            .timeIntervalSince1970
    }

    static func isPress(_ step: LiveE2EScenario.Step) -> Bool {
        if case .press = step { return true }
        return false
    }

    static func isSay(_ step: LiveE2EScenario.Step) -> Bool {
        if case .say = step { return true }
        return false
    }

    static func precedes(_ earlier: Int?, _ later: Int?) -> Bool {
        guard let earlier, let later else { return false }
        return earlier < later
    }

    static func carriesProtocolText(_ text: String) -> Bool {
        ["load_skill", "load_tool", "{\""].contains { text.contains($0) }
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
    }
}
