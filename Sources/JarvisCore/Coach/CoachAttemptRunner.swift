import Foundation

/// Only grows, so a leaf lock suffices: it never takes the driver's lock or the runner's.
/// `@unchecked Sendable`: the count is guarded by `lock`.
final class CoachTranscriptLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var committed = 0

    var committedCount: Int {
        lock.withLock { committed }
    }

    func commit(through count: Int) {
        lock.withLock {
            if count > committed { committed = count }
        }
    }
}

/// @unchecked Sendable: `runnerLock` guards loads, compaction state, and attempt numbering; the
/// history, transcript, ledger, and adapters synchronize themselves.
final class CoachAttemptRunner: @unchecked Sendable {
    private let config: Config
    private let transcript: RollingTranscript
    private let screen: ScreenCapturing
    private let overlay: OverlayRendering
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let history = CoachHistory()
    private let coachingAttempts: (any CoachingAttemptAuditing)?
    private let activity: (any ActivityEventRecording)?
    private let ledger: CoachTranscriptLedger
    /// Resolved once at Start, not per attempt, so declared schemas never drift from the prompt.
    private let capabilities: CoachCapabilities

    private let runnerLock = NSLock()
    private var nextAttemptID = 0
    /// Tools by name, skills under a `skill:` key. Added only when the loading attempt commits, so
    /// "already loaded" holds exactly when the content is in replayed history.
    private var loadedCapabilities: Set<String> = []
    private var isCompacting = false
    private var compactionRequested = false
    private var compactionTask: Task<Void, Never>?
    private var backgroundWorkStopped = false

    init(
        config: Config,
        transcript: RollingTranscript,
        screen: ScreenCapturing,
        overlay: OverlayRendering,
        clock: Clock,
        sessionStart: TimeInterval,
        coachingAttempts: (any CoachingAttemptAuditing)?,
        activity: (any ActivityEventRecording)?,
        ledger: CoachTranscriptLedger,
        capabilities: CoachCapabilities
    ) {
        self.capabilities = capabilities
        self.config = config
        self.transcript = transcript
        self.screen = screen
        self.overlay = overlay
        self.clock = clock
        self.sessionStart = sessionStart
        self.coachingAttempts = coachingAttempts
        self.activity = activity
        self.ledger = ledger
    }

    private func takeNextAttemptID() -> Int {
        runnerLock.withLock {
            nextAttemptID += 1
            return nextAttemptID
        }
    }

    /// The longest sensible chain (load skill, load tool, search, capture, speak) is five
    /// responses; two spare absorb a second skill or one wasted response.
    private let maxToolIterations = 7

    struct PendingCoachingWork {
        var reason: TriggerReason
        /// A retry of a failed press is automatic, so it clears this unless another press joins.
        var bypassesTranscriptionSettlement: Bool
        var wake: CoachingAttemptAuditEvent.Wake = .trigger
        /// Carried into retries, so each tool gets one replaceable slot: a second search replaces
        /// the first's stale result. Plain user context only, never reasoning, tool ids, or call
        /// linkage.
        var screenObservation: [ChatMessage] = []
        var prepNotesObservation: ChatMessage?
        var observations: [ChatMessage] {
            screenObservation + (prepNotesObservation.map { [$0] } ?? [])
        }
        var preparedManualReason: TriggerReason?
        /// Speech finalized during inference lies past this boundary, so a failure cannot discard
        /// it.
        var attemptedTranscriptBoundary = 0

        init(reason: TriggerReason) {
            self.reason = reason
            bypassesTranscriptionSettlement = reason.isManual
        }
    }

    enum AttemptResult {
        case completed(TurnOutcome)
        case failed(
            outcome: TurnOutcome,
            failure: ProviderFailure,
            work: PendingCoachingWork
        )
        case skipped(TurnOutcome)
        case cancelled
    }

    struct AttemptExecution {
        let id: Int?
        let result: AttemptResult
    }

    private static func unusableResponse(
        _ message: String, from target: BrainTarget
    ) -> ProviderFailure {
        ProviderFailure(
            source: .brain(target.provider), stage: .response, category: .response,
            disposition: .temporary, identity: .init(), message: message)
    }

    /// Nil unless `permitted` includes speak, so an automatic turn (nil `permitted`) fails instead.
    private static func spokenProse(_ text: String?, permitted: [String]?,
                                    detailEnabled: Bool) -> ToolInvocation? {
        guard permitted?.contains(speakToolName) == true, let text,
              let first = text.range(of: #"\S.*"#, options: .regularExpression) else { return nil }
        let rest = text[first.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return .speak(
            callId: "runner_" + UUID().uuidString.prefix(8).lowercased(),
            lines: [text[first].trimmingCharacters(in: .whitespaces)],
            detail: detailEnabled && !rest.isEmpty ? rest : nil)
    }

    func runAttempt(
        _ pendingWork: PendingCoachingWork,
        using attempt: CoachDriver.AttemptBrain
    ) async -> AttemptExecution {
        if Task.isCancelled {
            jlog("… attempt cancelled (stopped) before handling")
            return AttemptExecution(id: nil, result: .cancelled)
        }

        var work = pendingWork
        let reason = work.reason
        if case .silence(let seconds) = reason {
            jlog("🤫 quiet for \(Int(seconds))s")
        }

        let now = clock.now()
        let context = TriggerContext(
            reason: reason,
            sessionElapsedSeconds: now - sessionStart)
        let transcriptStartIndex = ledger.committedCount
        let delta = transcript.renderFrom(index: transcriptStartIndex)
        work.attemptedTranscriptBoundary = delta.upTo
        let classifications = delta.lines.map { TurnSubstance.classification(of: $0.text) }
        let brainFacingOffsets = classifications.indices.filter {
            classifications[$0].isSubstantive
        }
        let substantiveLines = brainFacingOffsets.map { delta.lines[$0] }
        let brainFacingTranscriptIndices = Set(brainFacingOffsets.map {
            transcriptStartIndex + $0
        })
        let substantiveDeltaText = RollingTranscript.render(substantiveLines)
        let attemptID = takeNextAttemptID()
        coachingAttempts?.recordStarted(
            attemptID: attemptID,
            wake: work.wake,
            reason: reason,
            target: attempt.target,
            transcriptStartIndex: transcriptStartIndex,
            transcriptLines: delta.lines,
            classifications: classifications,
            brainFacingTranscriptIndices: brainFacingTranscriptIndices)

        let userText = [
            substantiveDeltaText.isEmpty
                ? nil
                : JarvisPrompts.Coach.newSpeech(substantiveDeltaText),
            context.promptLine,
        ].compactMap { $0 }.joined(separator: "\n\n")
        var turnMessages = userText.isEmpty ? work.observations : [.user(userText)] + work.observations

        if turnMessages.isEmpty {
            let preview = delta.lines.isEmpty
                ? "nothing new"
                : String(delta.lines.map(\.text).joined(separator: " · ").prefix(80))
            jlog("… skipped as filler (\(preview)) — not calling the brain")
            ledger.commit(through: delta.upTo)
            return AttemptExecution(id: attemptID, result: .skipped(.skippedFillerOnly))
        }
        let systemPrompt = JarvisPrompts.Coach.system(capabilities: capabilities)
        let historyBase: [ChatMessage] = [.system(systemPrompt)] + history.snapshot()
        if reason.isManual && work.preparedManualReason != reason {
            if let prompt = context.promptLine {
                jlog("⌨️ coaching shortcut — \(prompt)")
                switch reason {
                case .manualCode: activity?.record(.manualCode(prompt: prompt))
                case .manualExplanation: activity?.record(.manualExplanation(prompt: prompt))
                default: activity?.record(.manualHint(prompt: prompt))
                }
            }
            let screen = self.screen
            let shot = await Self.captureScreen(using: screen, selecting: attempt.plan.screen)
            if Task.isCancelled {
                jlog("… attempt cancelled (stopped) after capture")
                return AttemptExecution(id: attemptID, result: .cancelled)
            }
            if let shot {
                jlog("👁 looking at your screen")
                activity?.record(.screenViewed(imageBase64JPEG: shot.imageBase64))
                var observations: [ChatMessage] = [.userImage(shot.imageBase64)]
                if !shot.textEvidence.isEmpty {
                    let lines = shot.textEvidence.reduce(0) {
                        $0 + $1.text.count(where: { $0 == "\n" }) + 1
                    }
                    jlog("🔤 read \(lines) lines of on-screen text")
                    observations.append(.user(JarvisPrompts.Coach.screenText(
                        shot.textEvidence,
                        capturedAt: RollingTranscript.stamp(clock.now() - sessionStart))))
                }
                work.screenObservation = observations
            } else {
                jlog("👁 screenshot failed")
                activity?.record(.screenViewFailed)
                work.screenObservation = [
                    .user(JarvisPrompts.Coach.manualHintCaptureFailed),
                ]
            }
            turnMessages = userText.isEmpty ? work.observations : [.user(userText)] + work.observations
            work.preparedManualReason = reason
        }

        jlog("💭 thinking… [\(attempt.target.provider.displayName)]")

        var requestPhase: CoachingAttemptAuditEvent.RequestPhase = .initial
        var requestSequence = 1
        // Owned by this attempt, like the conversation whose streamed deltas it turns into overlay
        // snapshots.
        let relay = ReplyProgressRelay(
            overlay: overlay, config: config, detailEnabled: capabilities.detailEnabled)
        let conversation: any BrainConversation
        do {
            let requestContext = CoachingRequestAttribution.context(
                attemptID: attemptID,
                wake: work.wake,
                reason: reason,
                phase: requestPhase,
                sequence: requestSequence)
            conversation = try await CoachingRequestAttribution.$current.withValue(requestContext) {
                try await attempt.brain.makeConversation(progress: relay.sink)
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                jlog("… attempt cancelled (interrupted)")
                return AttemptExecution(id: attemptID, result: .cancelled)
            }
            let failure = ProviderFailure(
                unclassified: error, source: .brain(attempt.target.provider), stage: .request)
            jlog("Jarvis coach: brain conversation failed on \(reason) via "
                 + "\(attempt.target.provider.displayName): \(failure.errorDescription ?? "")")
            return AttemptExecution(
                id: attemptID,
                result: .failed(outcome: .brainError, failure: failure, work: work))
        }

        // Failure and cancellation discard these, so "already loaded" never cites unsent history.
        var loadedThisAttempt: Set<String> = []
        var refusedProse = false
        let alreadyLoaded = runnerLock.withLock { loadedCapabilities }

        // Preload the coding skill as a synthetic call and result, saving a Show code press a round
        // trip. It goes before the user messages so the request still ends in user text.
        if reason == .manualCode,
           let coding = capabilities.skill(named: JarvisPrompts.Coach.showCodeSkillName),
           !alreadyLoaded.contains(CoachCapabilities.loadedKey(forSkill: coding.name)) {
            let callID = "runner_" + UUID().uuidString.prefix(8).lowercased()
            turnMessages.insert(contentsOf: [
                .assistantToolCalls([RawToolCall(
                    id: callID, name: CoachCapabilities.loadSkillName,
                    argumentsJSON: #"{"name":"\#(coding.name)"}"#)]),
                .init(role: .tool, text: JarvisPrompts.Coach.loadSkillResult(coding),
                      toolCallId: callID),
            ], at: 0)
            loadedThisAttempt.insert(CoachCapabilities.loadedKey(forSkill: coding.name))
            jlog("📎 preloaded the \(coding.name) skill for the Show code press")
            activity?.record(.capabilityLoaded(kind: .skill, name: coding.name))
        }

        let result: AttemptResult = await { () async -> AttemptResult in
            var iterations = 0
            /// Whether the current request's reply reached the overlay. A request that showed
            /// nothing must not wait on the main actor to withdraw nothing.
            var shown = false

            /// A reply that streamed but is not being delivered leaves the overlay.
            func withdraw() async {
                guard shown else { return }
                shown = false
                await MainActor.run { self.overlay.showReplyProgress(nil, perLineSeconds: []) }
            }

            /// Delivers one hint, records it, and commits the turn: the attempt's terminal action.
            func speak(callID: String, lines: [String], requestedDetail: String?) async -> AttemptResult {
                if Task.isCancelled {
                    jlog("… attempt cancelled (stopped) before speaking")
                    await withdraw()
                    return .cancelled
                }
                jlog("💬 \(lines.joined(separator: " "))")
                // Undeclared `detail` never reaches the overlay, history, or Activity.
                let parsedDetail = capabilities.detailEnabled
                    ? requestedDetail.flatMap(ReplyDetail.init(markdown:))
                    : nil
                for reason in parsedDetail?.dropped ?? [] { jlog("Detail: \(reason)") }
                let delivery = await MainActor.run { () -> (accepted: Bool, detail: ReplyDetail?) in
                    guard !Task.isCancelled else { return (false, nil) }
                    return (true, self.overlay.deliver(lines, perLineSeconds: lines.map {
                        OverlayTiming.displaySeconds(for: $0, config: self.config)
                    }, detail: parsedDetail))
                }
                guard delivery.accepted else {
                    await withdraw()
                    return .cancelled
                }
                let delivered = delivery.detail
                activity?.record(.tip(lines: lines, detail: delivered?.deliveredMarkdown))
                // History records the detail actually shown, not blocks the runtime dropped.
                var arguments: [String: Any] = ["lines": lines]
                if capabilities.detailEnabled {
                    arguments["detail"] = delivered?.deliveredMarkdown ?? NSNull()
                }
                let data = try! JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
                // Rebuilt, not copied, so a hint spoken from prose still commits a call.
                turnMessages.append(.assistantToolCalls([RawToolCall(
                    id: callID, name: speakToolName,
                    argumentsJSON: String(decoding: data, as: UTF8.self))]))
                turnMessages.append(.init(
                    role: .tool,
                    text: JarvisPrompts.Coach.tipShown(dropped: parsedDetail?.dropped ?? []),
                    toolCallId: callID))
                history.commit(turnMessages)
                commitLoads(loadedThisAttempt)
                ledger.commit(through: delta.upTo)
                return .completed(.spoke)
            }

            /// The hint as the stream left it, committed like a completed reply. Nothing is
            /// synthesized: the lines the user read stay, with the detail written so far.
            func speak(_ streamed: BrainReplyProgress) async -> AttemptResult {
                let detail = streamed.detailMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines)
                return await speak(
                    callID: "runner_" + UUID().uuidString.prefix(8).lowercased(),
                    lines: streamed.closedLines,
                    requestedDetail: detail.flatMap { $0.isEmpty ? nil : $0 })
            }

            while iterations < maxToolIterations {
                iterations += 1
                let loaded = alreadyLoaded.union(loadedThisAttempt)
                let tools = capabilities.callable(loaded: loaded)
                // A press must end in a hint and already sent the screen, so it never gets
                // stay_silent or capture_screen.
                let toolChoice: ToolChoice
                if reason.isManual {
                    let permitted = tools.map(\.name).filter {
                        $0 != staySilentTool.name && $0 != captureScreenTool.name
                    }
                    toolChoice = iterations == maxToolIterations || permitted == [speakToolName]
                        ? .force(speakToolName)
                        : .allowed(permitted)
                } else {
                    toolChoice = .required
                }
                relay.beginRequest()
                let response: BrainResponse
                do {
                    let requestContext = CoachingRequestAttribution.context(
                        attemptID: attemptID,
                        wake: work.wake,
                        reason: reason,
                        phase: requestPhase,
                        sequence: requestSequence)
                    response = try await CoachingRequestAttribution.$current.withValue(requestContext) {
                        try await conversation.respond(
                            messages: historyBase + turnMessages,
                            tools: tools,
                            toolChoice: toolChoice)
                    }
                } catch {
                    let streamed = await relay.endRequest()
                    shown = streamed?.hasText == true
                    if Task.isCancelled || error is CancellationError {
                        await withdraw()
                        jlog("… attempt cancelled (interrupted)")
                        return .cancelled
                    }
                    let failure = ProviderFailure(
                        unclassified: error, source: .brain(attempt.target.provider),
                        stage: .request)
                    jlog("Jarvis coach: brain request failed on \(reason) via "
                         + "\(attempt.target.provider.displayName): \(failure.errorDescription ?? "")")
                    // Lines the user has read stay on screen and commit with the detail so far.
                    // An array that closed empty showed nothing, so it has nothing to keep.
                    if let streamed, streamed.linesComplete, !streamed.closedLines.isEmpty {
                        jlog("Detail: cut short (\(failure.category.rawValue))")
                        return await speak(streamed)
                    }
                    await withdraw()
                    return .failed(outcome: .brainError, failure: failure, work: work)
                }
                let streamed = await relay.endRequest()
                shown = streamed?.hasText == true

                if Task.isCancelled {
                    await withdraw()
                    jlog("… attempt cancelled (stopped) mid-think")
                    return .cancelled
                }

                // Incomplete output can't prove a terminal action, even if it contains one, unless
                // its lines closed on the way: those stay on screen and commit as they were read.
                if let incompleteReason = response.incompleteReason {
                    if let streamed, streamed.linesComplete, !streamed.closedLines.isEmpty {
                        jlog("⚠️ response incomplete (\(incompleteReason)) after its lines closed — keeping the hint")
                        jlog("Detail: cut short (\(incompleteReason))")
                        return await speak(streamed)
                    }
                    jlog("⚠️ response incomplete (\(incompleteReason)) — scheduling fresh attempt")
                    await withdraw()
                    return .failed(
                        outcome: .truncated,
                        failure: Self.unusableResponse(
                            "incomplete response: \(incompleteReason)", from: attempt.target),
                        work: work)
                }

                // Checked here because not every provider enforces a narrowed tool choice.
                // Nil when any offered tool may run.
                let permitted: [String]? = switch toolChoice {
                case .force(let name): [name]
                case .allowed(let names): names
                case .auto, .required: nil
                }
                let atCap = iterations == maxToolIterations

                // Every replayed call needs a result, or the provider's linkage validation fails.
                func appendToolContinuation(
                    toolCallId: String,
                    resultText: String,
                    extraMessages: [ChatMessage] = [],
                    newPhase: CoachingAttemptAuditEvent.RequestPhase
                ) {
                    if !response.outputItemsJSON.isEmpty {
                        turnMessages.append(.rawItems(response.outputItemsJSON, calls: response.rawToolCalls))
                    } else {
                        turnMessages.append(.assistantToolCalls(response.rawToolCalls))
                    }
                    turnMessages.append(.init(role: .tool, text: resultText, toolCallId: toolCallId))
                    for extra in response.rawToolCalls where extra.id != toolCallId {
                        turnMessages.append(.init(
                            role: .tool, text: JarvisPrompts.Coach.extraCallNotExecuted,
                            toolCallId: extra.id))
                    }
                    turnMessages.append(contentsOf: extraMessages)
                    requestPhase = newPhase
                    requestSequence += 1
                }

                // The first raw call decides: `toolCalls` omits calls whose arguments didn't parse,
                // so its first entry may not be the model's first call.
                let firstParsed: ToolInvocation? = if let raw = response.rawToolCalls.first {
                    response.toolCalls.first { $0.callID == raw.id }
                } else {
                    response.toolCalls.first
                }
                let call: ToolInvocation
                if let parsed = firstParsed {
                    if permitted?.contains(parsed.toolName) ?? true {
                        call = parsed
                    } else if atCap, let spoken = Self.spokenProse(
                        response.outputText, permitted: permitted,
                        detailEnabled: capabilities.detailEnabled) {
                        jlog("⚠️ \(parsed.toolName) isn't allowed on a shortcut's last response — "
                             + "speaking the reply's text")
                        call = spoken
                    } else if atCap {
                        jlog("⚠️ \(parsed.toolName) isn't allowed on a shortcut's last response — "
                             + "scheduling fresh attempt")
                        await withdraw()
                        return .failed(
                            outcome: .brainError,
                            failure: Self.unusableResponse(
                                "provider called \(parsed.toolName), which this response did not permit",
                                from: attempt.target),
                            work: work)
                    } else {
                        jlog("⚠️ \(parsed.toolName) isn't allowed on a shortcut — asking for the hint again")
                        appendToolContinuation(
                            toolCallId: parsed.callID,
                            resultText: JarvisPrompts.Coach.notPermittedOnShortcut(parsed.toolName),
                            newPhase: requestPhase)
                        await withdraw()
                        continue
                    }
                } else if let raw = response.rawToolCalls.first {
                    if atCap, let spoken = Self.spokenProse(
                        response.outputText, permitted: permitted,
                        detailEnabled: capabilities.detailEnabled) {
                        jlog("⚠️ \(raw.name) couldn't run on the last response — speaking the reply's text")
                        call = spoken
                    } else if let tool = capabilities.tool(named: raw.name) {
                        guard !atCap else {
                            jlog("⚠️ \(tool.name) arguments didn't match its schema on the last response — "
                                 + "scheduling fresh attempt")
                            await withdraw()
                            return .failed(
                                outcome: .brainError,
                                failure: Self.unusableResponse(
                                    "provider called \(tool.name) with arguments that did not match its schema",
                                    from: attempt.target),
                                work: work)
                        }
                        jlog("⚠️ \(tool.name) arguments didn't match its schema — asking for the call again")
                        appendToolContinuation(
                            toolCallId: raw.id,
                            resultText: JarvisPrompts.Coach.argumentsRejected(tool),
                            newPhase: requestPhase)
                        await withdraw()
                        continue
                    } else {
                        jlog("⚠️ \(raw.name) isn't available in this session — telling the model so")
                        appendToolContinuation(
                            toolCallId: raw.id,
                            resultText: JarvisPrompts.Coach.toolUnavailable(raw.name),
                            newPhase: requestPhase)
                        await withdraw()
                        continue
                    }
                } else if !atCap, !refusedProse,
                          permitted?.contains(speakToolName) == true,
                          let prose = response.outputText,
                          !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Only once per attempt: a refusal re-sends the whole uncached request with the
                    // screenshot. `CoachHistory.commit` drops both messages.
                    jlog("⚠️ reply had no tool call — asking for the speak call again")
                    refusedProse = true
                    turnMessages.append(.init(role: .assistant, text: prose))
                    turnMessages.append(.user(JarvisPrompts.Coach.replyMustCallSpeak(
                        detailEnabled: capabilities.detailEnabled)))
                    requestSequence += 1
                    await withdraw()
                    continue
                } else if let spoken = Self.spokenProse(
                    response.outputText, permitted: permitted,
                    detailEnabled: capabilities.detailEnabled) {
                    jlog("⚠️ reply still had no tool call — speaking its text as the reply")
                    call = spoken
                } else {
                    jlog("⚠️ required coaching action missing — scheduling fresh attempt")
                    await withdraw()
                    return .failed(
                        outcome: .brainError,
                        failure: Self.unusableResponse(
                            "provider returned no required coaching tool call",
                            from: attempt.target),
                        work: work)
                }

                // A switched-off tool stays off whatever the model emits: answer, don't run or
                // fail.
                guard let called = capabilities.tool(named: call.toolName) else {
                    jlog("⚠️ \(call.toolName) isn't available in this session — telling the model so")
                    appendToolContinuation(
                        toolCallId: call.callID,
                        resultText: JarvisPrompts.Coach.toolUnavailable(call.toolName),
                        newPhase: requestPhase)
                    await withdraw()
                    continue
                }
                if called.deferLoading, !loaded.contains(called.name) {
                    jlog("… \(called.name) was called before it was loaded — running it anyway")
                }

                switch call {
                case .captureScreen(let callID):
                    let screen = self.screen
                    let shot = await Self.captureScreen(using: screen, selecting: attempt.plan.screen)
                    if Task.isCancelled {
                        jlog("… attempt cancelled (stopped) after capture")
                        return .cancelled
                    }
                    if let shot {
                        jlog("👁 looking at your screen")
                        activity?.record(.screenViewed(imageBase64JPEG: shot.imageBase64))
                        if !shot.textEvidence.isEmpty {
                            let lines = shot.textEvidence.reduce(0) {
                                $0 + $1.text.count(where: { $0 == "\n" }) + 1
                            }
                            jlog("🔤 read \(lines) lines of on-screen text")
                        }
                        let capturedAt = RollingTranscript.stamp(clock.now() - sessionStart)
                        work.screenObservation = [
                            .user(JarvisPrompts.Coach.captureResult(
                                textEvidence: shot.textEvidence, capturedAt: capturedAt)),
                            .userImage(shot.imageBase64),
                        ]
                        appendToolContinuation(
                            toolCallId: callID,
                            resultText: JarvisPrompts.Coach.captureResult(
                                textEvidence: shot.textEvidence, capturedAt: capturedAt),
                            extraMessages: [.userImage(shot.imageBase64)],
                            newPhase: .captureScreenContinuation)
                    } else {
                        jlog("👁 screenshot failed")
                        activity?.record(.screenViewFailed)
                        work.screenObservation = [
                            .user(JarvisPrompts.Coach.earlierCaptureFailed),
                        ]
                        appendToolContinuation(
                            toolCallId: callID,
                            resultText: JarvisPrompts.Coach.captureFailed,
                            newPhase: .captureScreenContinuation)
                    }

                case .speak(let callID, let lines, let requestedDetail):
                    return await speak(callID: callID, lines: lines, requestedDetail: requestedDetail)

                case .staySilent:
                    await withdraw()
                    if Task.isCancelled {
                        jlog("… attempt cancelled (stopped) before recording silence")
                        return .cancelled
                    }
                    jlog("… nothing useful to add, staying silent")
                    activity?.record(.stayedSilent)
                    commitIfWorthKeeping(turnMessages, deltaText: substantiveDeltaText)
                    commitLoads(loadedThisAttempt)
                    ledger.commit(through: delta.upTo)
                    return .completed(.silentByModel)

                case .searchPrepNotes(let callID, let query):
                    if Task.isCancelled {
                        jlog("… attempt cancelled (stopped) before searching prep notes")
                        return .cancelled
                    }
                    // No port yet (still indexing, or nothing usable). `prepNotesObservation` stays
                    // unset so a retry after the index lands searches for real.
                    guard let prepMaterial = attempt.prepMaterial else {
                        jlog("📎 no prep-notes index yet (still building, or no source held usable "
                             + "text) — answering without them")
                        activity?.record(.prepNotesUnavailable)
                        appendToolContinuation(
                            toolCallId: callID,
                            resultText: JarvisPrompts.Coach.prepNotesUnavailable,
                            newPhase: .searchPrepNotesContinuation)
                        continue
                    }
                    let results = prepMaterial.search(query: query)
                    jlog("📎 searched prep notes for \"\(query)\" — \(results.count) match(es)")
                    activity?.record(.prepNotesSearched(query: query, matchCount: results.count))
                    work.prepNotesObservation = .user(JarvisPrompts.Coach.prepNotesResult(results))
                    appendToolContinuation(
                        toolCallId: callID,
                        resultText: JarvisPrompts.Coach.prepNotesResult(results),
                        newPhase: .searchPrepNotesContinuation)

                case .loadTool(let callID, let name):
                    let resultText: String
                    if let tool = capabilities.tool(named: name), tool.deferLoading {
                        if loaded.contains(name) {
                            jlog("📎 \(name) was already loaded — saying so instead of repeating it")
                            resultText = JarvisPrompts.Coach.loadToolAlreadyLoaded(name)
                        } else {
                            loadedThisAttempt.insert(tool.name)
                            jlog("📎 loaded the \(tool.name) tool")
                            activity?.record(.capabilityLoaded(kind: .tool, name: tool.name))
                            resultText = JarvisPrompts.Coach.loadToolResult(tool)
                        }
                    } else {
                        jlog("⚠️ nothing named \(name) to load — telling the model so")
                        resultText = JarvisPrompts.Coach.toolUnavailable(name)
                    }
                    appendToolContinuation(
                        toolCallId: callID,
                        resultText: resultText,
                        newPhase: .loadToolContinuation)

                case .loadSkill(let callID, let name):
                    let resultText: String
                    if let skill = capabilities.skill(named: name) {
                        if loaded.contains(CoachCapabilities.loadedKey(forSkill: name)) {
                            jlog("📎 the \(name) skill was already loaded — saying so instead of "
                                 + "repeating it")
                            resultText = JarvisPrompts.Coach.loadSkillAlreadyLoaded(name)
                        } else {
                            loadedThisAttempt.insert(CoachCapabilities.loadedKey(forSkill: skill.name))
                            jlog("📎 loaded the \(skill.name) skill")
                            activity?.record(.capabilityLoaded(kind: .skill, name: skill.name))
                            resultText = JarvisPrompts.Coach.loadSkillResult(skill)
                        }
                    } else {
                        jlog("⚠️ no skill named \(name) to load — telling the model so")
                        resultText = JarvisPrompts.Coach.skillUnavailable(name)
                    }
                    appendToolContinuation(
                        toolCallId: callID,
                        resultText: resultText,
                        newPhase: .loadSkillContinuation)
                }
                // The tool ran and the loop goes on: this response delivered nothing.
                await withdraw()
            }

            jlog("⚠️ tool loop exhausted — scheduling fresh attempt")
            await withdraw()
            return .failed(
                outcome: .exhausted,
                failure: Self.unusableResponse(
                    "coaching tool loop exhausted", from: attempt.target),
                work: work)
        }()

        await conversation.finish()
        if case .completed = result {
            startCompactionIfIdle(using: attempt.summarizer ?? attempt.brain)
        }
        return AttemptExecution(id: attemptID, result: result)
    }

    private func commitIfWorthKeeping(_ turn: [ChatMessage], deltaText: String) {
        guard !deltaText.isEmpty || turn.count > 1 else { return }
        history.commit(turn)
    }

    /// Call only after the turn is committed.
    private func commitLoads(_ names: Set<String>) {
        guard !names.isEmpty else { return }
        runnerLock.withLock { loadedCapabilities.formUnion(names) }
    }

    /// Runs the blocking capture off the cooperative executor.
    private static func captureScreen(
        using screen: ScreenCapturing,
        selecting selection: ScreenCaptureSelection
    ) async -> ScreenSnapshot? {
        let capture = Task.detached(priority: .userInitiated) { () -> ScreenSnapshot? in
            guard !Task.isCancelled else { return nil }
            return screen.capture(selection)
        }
        return await withTaskCancellationHandler {
            // Await the producer itself so cancellation can't outrun helper exit and JPEG cleanup.
            await capture.value
        } onCancel: {
            capture.cancel()
            screen.cancelCapture()
        }
    }

    // MARK: - History compaction

    /// Off the attempt path so speech isn't held behind a summary. One run at a time: overlapping
    /// runs both replace `0..<prefixCount`, destroying real turns.
    func startCompactionIfIdle(using client: BrainClient) {
        guard history.estimatedTokens > config.historyCompactionTokenThreshold else { return }
        runnerLock.lock()
        // A turn resuming from `conversation.finish()` after teardown must not start a request
        // that nothing will drain.
        guard !backgroundWorkStopped else {
            runnerLock.unlock()
            return
        }
        guard !isCompacting else {
            // Coalesce, don't drop: this attempt's fresh OCR may invalidate the running summary.
            compactionRequested = true
            runnerLock.unlock()
            return
        }
        isCompacting = true
        compactionRequested = false
        let task = Task.detached(priority: .utility) { [self] in
            await runCompactionPasses(using: client)
        }
        compactionTask = task
        runnerLock.unlock()
    }

    private func runCompactionPasses(using client: BrainClient) async {
        while true {
            await compactIfNeeded(using: client)
            let overThreshold = history.estimatedTokens > config.historyCompactionTokenThreshold
            let runAgain: Bool = runnerLock.withLock {
                guard compactionRequested, overThreshold, !Task.isCancelled else {
                    isCompacting = false
                    compactionTask = nil
                    return false
                }
                compactionRequested = false
                return true
            }
            if !runAgain { return }
        }
    }

    /// Returns the cancelled compaction task so teardown can drain it before sealing the audit.
    @discardableResult
    func cancelBackgroundWork() -> Task<Void, Never>? {
        runnerLock.lock()
        backgroundWorkStopped = true
        compactionRequested = false
        let task = compactionTask
        compactionTask = nil
        runnerLock.unlock()
        task?.cancel()
        return task
    }

    /// Fails soft: never counts against route health.
    private func compactIfNeeded(using client: BrainClient) async {
        guard history.estimatedTokens > config.historyCompactionTokenThreshold else { return }
        guard let (oldest, count, revision) = history.compactionPrefix() else { return }
        do {
            let response = try await client.respond(
                messages: [
                    .system(JarvisPrompts.HistorySummary.system),
                    .user(JarvisPrompts.HistorySummary.input(oldest)),
                ],
                tools: [],
                toolChoice: .auto)
            guard let summary = response.outputText, !summary.isEmpty else {
                jlog("… memory compaction returned nothing — keeping full history for now")
                return
            }
            // A summary that wins the race with teardown must not mutate history.
            guard !Task.isCancelled else { return }
            guard history.compact(prefixCount: count, summary: summary, revision: revision) else {
                jlog("… discarded a summary written against superseded screen text — will retry later")
                return
            }
            jlog("… condensed session memory to ~\(history.estimatedTokens) tokens")
        } catch {
            jlog("… memory compaction failed (will retry later): \(error.localizedDescription)")
        }
    }
}
