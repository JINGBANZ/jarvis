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

    // The short scenarios run first: a missing grant, key, or sign-in shows within minutes.

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

    @Test func scenarioB() async throws {
        guard let launcher = await LiveE2ELauncher.begin(scenario: "B") else { return }
        let launch = try await launcher.launch()
        var results = LiveE2EResults(scenario: "B")
        if let evidence = Self.requireEvidence(launch, &results) {
            let presses = launch.stepIndices(Self.isPress)
            let says = launch.stepIndices(Self.isSay)
            guard presses.count == 2, says.count == 1 else {
                results.check("B", false,
                              "B has 2 presses and 1 spoken step (saw \(presses.count), \(says.count))")
                try launcher.finish(results)
                return
            }
            let b1 = launch.attemptChain(forStep: presses[0])      // Show code, on a cold session
            let b3 = launch.attemptChain(forStep: presses[1])      // Explain more
            let b2 = launch.attemptChain(forStep: says[0])
            Self.noteStalls([("B1", b1), ("B3", b3), ("B2", b2)], evidence, &results)
            let b1Rows = evidence.rows(inChain: b1)
            // Committed loads only: a retried press preloads again, exactly as a model load behaves,
            // so a provider stall must not read as two loads (the rule C10 counts by).
            let b1Loads = b1.filter(\.isCommitted)
                .flatMap { evidence.rows(in: $0).compactMap { $0.loadedCapability?.name } }
            let b1Screens = b1Rows.filter { $0.kind == "screenViewed" }.count
            let b1Tip = b1Rows.contains { $0.kind == "tip" }
            let b1Summary = "B1 Show code on Claude Code: \(b1Screens) screen view(s), "
                + "loads \(b1Loads), " + (b1Tip ? "a tip" : "no tip")
            results.note("C01", b1Summary)
            // The preload puts `coding` in the press's own request, so these are checks now.
            results.check("C09", b1Loads == ["coding"], "B1 loads exactly coding (saw \(b1Loads))")
            results.check("C17", b1Loads == ["coding"], "B1's chain loads nothing else (saw \(b1Loads))")
            results.time("B1 press-to-tip", seconds: Self.pressToTip(evidence, b1))
            results.time("B3 press-to-tip", seconds: Self.pressToTip(evidence, b3))

            // C22: the preload is a replayed `load_skill` call the runner wrote, ahead of the
            // press's own user messages, and it costs no round trip. Read from the attempt that
            // answered: a stalled attempt's retry preloads again by design, and `noteStalls` already
            // records the stall, so the chain as a whole would count it twice.
            let answeredRequests = b1.filter(\.isCommitted)
                .flatMap { evidence.traffic(for: $0) }
                .filter { $0.tag == "coach" }
            // Distinct call ids: an attempt that needed a second request replays the same preload.
            let preloads = Set(answeredRequests.flatMap(\.replayedFunctionCalls)
                .filter { $0.callID.hasPrefix("runner_") && $0.name == "load_skill"
                    && $0.arguments.contains("coding") }
                .map(\.callID))
            let loadRow = b1Rows.firstIndex { $0.kind == "capabilityLoaded" }
            let tipRow = b1Rows.lastIndex { $0.kind == "tip" }
            results.check("C22", [
                (preloads.count == 1,
                 "B1's answering attempt replays one runner-written load_skill for coding "
                    + "(saw \(preloads.count))"),
                (Self.precedes(loadRow, tipRow), "B1's load row precedes its tip"),
                // Only speak remains permitted on a press once the skill is in hand.
                (answeredRequests.count == 1,
                 "B1's answering attempt made one request (saw \(answeredRequests.count))"),
            ])

            // C24: the Show code reply's own block. The coding skill may legitimately answer with
            // no code when the approach itself is wrong, so this is recorded, not required.
            results.note("C24", "B1 delivered \(Self.describeDetail(evidence, b1))")
            // C25: Explain more always has something to say, and Activity is where it is read from.
            let b3Detail = Self.deliveredDetail(evidence, b3)
            results.check("C25", b3Detail?.isEmpty == false,
                          "B3's Explain more delivered a detail (saw \(Self.describeDetail(evidence, b3)))")

            let claude = Self.coachTraffic(evidence, on: .claudeSubscription)
            results.check("C16", [
                (!evidence.activity.contains {
                    ["behavioral", "system-design", "coding-with-ai"].contains($0.loadedCapability?.name ?? "")
                }, "switched-off skills never load"),
                (!evidence.activity.contains { $0.kind == "prepNotesSearched" }, "no prep search"),
                (!b2.isEmpty, "B2 ran an attempt"),
            ])
            results.note("C16", "B2 ended \(b2.last?.terminal ?? "without an attempt"), "
                + Self.describeDetail(evidence, b2))
            results.check("C18", [
                (!claude.isEmpty, "Claude Code coach requests were recorded"),
                (claude.allSatisfy { !($0.instructions ?? "").contains("search_prep_notes") },
                 "instructions never name search_prep_notes"),
                (claude.allSatisfy { !($0.instructions ?? "").contains("Tools you can load") },
                 "instructions carry no tools catalog or load-tool clause"),
            ])
            let catalogs = Set(claude.map { Self.skillCatalog(in: $0.instructions ?? "") })
            results.check("C19", catalogs == [["coding"]],
                          "the skills catalog lists only coding (saw \(catalogs.sorted { $0.count < $1.count }))")
            Self.noteReplyRecoveries(evidence, &results)
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
        let firstOpenAI = a4.flatMap { evidence.traffic(for: $0) }.first {
            $0.tag == "coach" && $0.provider == BrainProvider.openAI.rawValue
        }
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
            (a5.contains { evidence.traffic(for: $0).contains {
                $0.provider == BrainProvider.codexSubscription.rawValue
            } }, "A5 ran on Codex"),
        ])
        results.time("A5 question-to-tip", seconds: Self.questionToTip(evidence, a5))
        results.check("C09", loads(a1).contains("coding"), "A1 loaded coding (saw \(loads(a1)))")
        results.check("C10", committed == ["coding", "behavioral", "search_prep_notes", "system-design"],
                      "four loads, each once, in order (saw \(committed))")

        results.check("C11", [
            (a7.allSatisfy { !$0.isEmpty }, "both A7 presses ran an attempt"),
            (loads(a7[0]).isEmpty && loads(a7[1]).isEmpty,
             "neither A7 press loads anything: coding is already in the session"),
        ])
        let requestsPerPress = a7.map { chain in chain.last.map { evidence.traffic(for: $0).count } ?? 0 }
        if requestsPerPress != [1, 1] {
            results.note("C11", "A7 requests per press: \(requestsPerPress)")
        }

        results.check("C12", Self.hasDiagram(evidence, a4),
                      "A4's detail carries a mermaid block (saw \(Self.describeDetail(evidence, a4)))")
        results.note("C12", "A8 on Codex: \(Self.describeDetail(evidence, a8))")
        let unexpectedDiagrams = [("A1", a1), ("A3", a3), ("A5", a5), ("A6", a6),
                                  ("A7", a7[0]), ("A7", a7[1]), ("A9", a9)]
            .filter { Self.hasDiagram(evidence, $0.1) }.map(\.0)
        results.note("C13", unexpectedDiagrams.isEmpty
            ? "no diagram outside the architecture stage" : "diagram at \(unexpectedDiagrams)")

        // C14: loaded state survives both switches. OpenAI replays the load pairs the Claude
        // subscription made.
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
                    && replayedOutputs.contains(call.callID)
            }
        }
        let codexInstructions = Self.coachTraffic(evidence, on: .codexSubscription)
            .compactMap(\.instructions)
        results.check("C14", [
            (loadsBeforeSwitch.count == 3,
             "three loads committed before the OpenAI switch (saw \(loadsBeforeSwitch.map(\.name)))"),
            (!loadsBeforeSwitch.isEmpty && unreplayed.isEmpty,
             "A4 replays every earlier load pair with its result (missing \(unreplayed.map(\.name)))"),
            (evidence.activity.filter { $0.kind == "brainChangeApplied" }.count >= 2,
             "both brain switches applied"),
            (!codexInstructions.isEmpty && Set(codexInstructions).count == 1,
             "Codex's instructions never change"),
        ])

        var c15: [LiveE2EResults.Check] = []
        for provider in [BrainProvider.claudeSubscription, .codexSubscription] {
            let records = Self.coachTraffic(evidence, on: provider)
            let later = Set(records.compactMap(\.attemptID))
                .subtracting([records.first?.attemptID].compactMap { $0 })
            c15.append((later.count >= 2,
                        "\(provider.rawValue) coached at least two attempts after its first (saw \(later.count))"))
            c15.append((Set(records.compactMap(\.instructions)).count == 1,
                        "\(provider.rawValue) instructions stay identical"))
        }
        results.check("C15", c15)
        Self.noteReplyRecoveries(evidence, &results)

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
            (evidence.activity.filter { $0.kind == "manualHint" }.count == 2, "two hint shortcut rows"),
            (evidence.activity.filter { $0.kind == "manualCode" }.count == 1, "one Show code row"),
            (pressAttempts.allSatisfy { count("screenViewed", in: $0) == 1 && tip($0) != nil },
             "each press viewed the screen once and ended in a tip"),
            (tip(a7[0]) != nil && tip(a7[0])?.message != tip(a7[1])?.message,
             "the second A7 reply differs from the first"),
            (tip(a1) != nil && tip(a1)?.message != tip(a7[0])?.message, "A7's first hint differs from A1's"),
        ])

        // C22: a press made after `coding` is already loaded preloads nothing.
        let warmPreloads = a7[1].flatMap { evidence.traffic(for: $0) }
            .flatMap { $0.replayedFunctionCalls }
            .filter { $0.callID.hasPrefix("runner_") && $0.name == "load_skill" }
        results.check("C22", [
            (warmPreloads.isEmpty, "A7's Show code press replays no runner-written load"),
            (loads(a7[1]).isEmpty, "A7's Show code press records no load row"),
        ])

        // C23: every coach request in this scenario declares the session's one composed schema.
        let coachRequests = evidence.traffic.filter { $0.tag == "coach" }
        let schemas = Set(coachRequests.compactMap(\.speakParameters))
        results.check("C23", [
            (schemas == [["detail", "lines"]],
             "speak is declared with exactly lines and detail (saw \(schemas.sorted { $0.count < $1.count }))"),
            (coachRequests.allSatisfy { ($0.instructions ?? "").contains("# Detail") },
             "every coach request's instructions carry the Detail section"),
        ])

        // C24: the Show code press's own block, recorded rather than required.
        results.note("C24", "A7's Show code press delivered \(Self.describeDetail(evidence, a7[1]))")
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

    /// The coach requests one target made, in file order.
    static func coachTraffic(_ evidence: Evidence, on provider: BrainProvider) -> [Evidence.TrafficRecord] {
        evidence.traffic.filter { $0.tag == "coach" && $0.provider == provider.rawValue }
    }

    /// G08: the session ends last, its evidence seals, and no subscription helper outlives the app.
    static func checkCleanEnd(
        _ launch: LiveE2ELaunch, _ evidence: Evidence, endedByUser: Bool,
        _ results: inout LiveE2EResults
    ) {
        let last = evidence.activity.last
        var checks: [LiveE2EResults.Check] = [
            (last?.kind == "sessionEnded", "the last Activity row is the session end (saw \(last?.kind ?? "no rows"))"),
            (evidence.healthState == "complete", "audit health is complete (saw \(evidence.healthState ?? "missing"))"),
            (launch.leftoverHelperIDs.isEmpty, "no subscription helper survived (pids \(launch.leftoverHelperIDs))"),
        ]
        if endedByUser {
            checks.append((last?.message.contains("session ended by user") == true, "the session ended by user"))
        }
        results.check("G08", checks)
    }

    /// C20: a reply the runner answered instead of running, on any brain, is reported, never failed.
    static func noteReplyRecoveries(_ evidence: Evidence, _ results: inout LiveE2EResults) {
        let needles = ["isn't allowed on a shortcut", "didn't match its schema", "had no tool call",
                       "couldn't run on the last response", "isn't available in this session"]
        let sightings = needles.compactMap { needle -> String? in
            let count = evidence.debugLines(containing: needle).count
            return count > 0 ? "\(count) x \"\(needle)\"" : nil
        }
        results.note("C20", sightings.isEmpty ? "no reply recoveries" : sightings.joined(separator: ", "))
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
              let press = evidence.activity.last(where: {
                  ["manualHint", "manualCode", "manualExplanation"].contains($0.kind ?? "")
                      && $0.index < tip.index
              }),
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

    /// The `detail` of the speak call the attempt's last answering request carried.
    static func detail(_ evidence: Evidence, _ attempt: Attempt?) -> LiveSessionEvidence.SpeakDetail {
        guard let attempt else { return .noSpeakCall }
        return evidence.traffic(for: attempt).last { $0.speakDetail != .noSpeakCall }?.speakDetail
            ?? .noSpeakCall
    }

    /// What the overlay actually delivered, read from Activity rather than the response body: a
    /// refused-then-recovered reply on a `filteredAuto` target may carry no speak call at all.
    static func deliveredDetail(_ evidence: Evidence, _ chain: [Attempt]) -> String? {
        evidence.rows(inChain: chain).last { $0.kind == "tip" }?.response?.detail
    }

    /// Whether the delivered detail carries a fence of this kind, using the app's own parser.
    static func deliveredFences(_ evidence: Evidence, _ chain: [Attempt]) -> [String] {
        deliveredDetail(evidence, chain).map { ReplyDetail.fences(in: $0).map(\.language) } ?? []
    }

    static func hasDiagram(_ evidence: Evidence, _ chain: [Attempt]) -> Bool {
        deliveredFences(evidence, chain).contains("mermaid")
    }

    static func describeDetail(_ evidence: Evidence, _ chain: [Attempt]) -> String {
        guard let detail = deliveredDetail(evidence, chain) else { return "no detail delivered" }
        let fences = ReplyDetail.fences(in: detail).map { $0.language.isEmpty ? "text" : $0.language }
        return fences.isEmpty ? "prose only" : "fences \(fences)"
    }

    /// Skill names listed under the catalog heading of a system prompt.
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
