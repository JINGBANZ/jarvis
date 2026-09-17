import Testing
@testable import JarvisCore

@Suite struct ToolDefsTests {
    @Test func toolNames() {
        #expect(captureScreenTool.name == "capture_screen")
        #expect(speakToolName == "speak")
        #expect(staySilentTool.name == "stay_silent")
        #expect(coachTools(detailEnabled: true).map(\.name)
            == ["capture_screen", "speak", "stay_silent"])
    }

    /// `speak` returns the overlay lines pre-split in a strict `lines` array (Structured Outputs),
    /// so the client never splits a free-form string. Both session shapes stay strict-valid.
    @Test func bothSpeakSchemasAreStrict() {
        let withDetail = speakTool(detailEnabled: true).parametersJSON
        #expect(withDetail.contains("\"lines\""))
        // `detail` is declared nullable so strict Structured Outputs treats it as optional while it
        // stays in `required`.
        #expect(withDetail.contains(#""detail":{"type":["string","null"]"#))
        #expect(withDetail.contains(#""required":["lines","detail"]"#))
        #expect(withDetail.contains("\"additionalProperties\":false"))

        let without = speakTool(detailEnabled: false).parametersJSON
        #expect(!without.contains("detail"))
        #expect(without.contains(#""required":["lines"]"#))
        #expect(without.contains("\"additionalProperties\":false"))
        // Neither schema carries a limit the runtime enforces locally.
        #expect(!withDetail.contains("\"maxItems\""))
    }

    /// Nothing in the runtime decides what belongs in a detail: the schema, the description, and the
    /// guidance all say the same thing, and a loaded skill adds its own domain's rules.
    @Test func theDetailFieldIsGovernedByPromptTextAlone() {
        let tool = speakTool(detailEnabled: true)
        #expect(tool.parametersJSON.contains(
            "Markdown shown under the hint in the box. Null for an ordinary hint."))
        #expect(tool.description.contains(
            "Put a code block or a diagram in detail as Markdown; null for an ordinary hint."))
        #expect(tool.guidance.contains("# Detail"))
        #expect(!speakTool(detailEnabled: false).guidance.contains("# Detail"))
        #expect(!tool.guidance.contains("mermaid"))
    }

    @Test func coachToolsDescribeCaptureAndOverlayContracts() {
        #expect(JarvisPrompts.Coach.system.contains("capture_screen"))
        #expect(captureScreenTool.description.contains("one fresh result satisfies that request"))
        #expect(speakTool(detailEnabled: true).description.contains("up to 3 short overlay lines"))
        #expect(staySilentTool.description.contains("default for unsolicited turns"))
    }

    /// Each catalog line is the sentence the model chooses from, so they read the same way.
    @Test func everyBundledSkillDescriptionStartsWithUseWhen() {
        for skill in SkillCatalog.bundled() {
            #expect(skill.description.hasPrefix("Use when"), "\(skill.name)")
        }
    }

    /// A skill that tells the model to write a block into `detail` guards that rule on the box
    /// offering one, or a boxless session reads rules for a field it cannot send.
    @Test func aSkillThatAsksForABlockGuardsItOnTheBoxOfferingDetail() throws {
        for name in ["coding", "system-design"] {
            let skill = try #require(SkillCatalog.bundled().first { $0.name == name })
            let body = skill.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            #expect(body.lowercased().contains("when speak offers detail"), "\(name)")
        }
    }

    /// Each source's limits ride on its own label, so they reach the model only when that source is
    /// present, instead of sitting in every session's cached system prompt.
    @Test func capturedTextLabelsSourceCoverageAndUncertainty() {
        let browser = JarvisPrompts.Coach.captureResult(textEvidence: [ScreenTextEvidence(
            text: "earlier requirement",
            source: .browserAccessibility,
            coverage: .activeTabAccessibilityTree,
            truncated: true)], capturedAt: "00:03")
        #expect(browser.contains("Chrome Accessibility"))
        #expect(browser.contains("may include off-screen text"))
        #expect(browser.contains("may miss canvas, images, diagrams, lazy content, and parts of "
            + "virtualized editors"))
        #expect(browser.contains("truncated"))
        #expect(browser.contains("earlier requirement"))

        let ocr = JarvisPrompts.Coach.captureResult(textEvidence: [ScreenTextEvidence(
            text: "visible code", source: .onDeviceOCR, coverage: .currentViewport)],
            capturedAt: "00:03")
        #expect(ocr.contains("On-device OCR"))
        // The stamp and the clause are the whole point: the same text sits in memory long after this
        // turn, and the stamp alone let one live run answer a later question from it.
        #expect(ocr.contains("captured at [00:03]"))
        #expect(ocr.contains("the screen may have changed since"))
        #expect(ocr.contains("screenshot viewport"))
        #expect(ocr.contains("may misread tokens"))
    }

    /// The guidance keeps the three rules that hold for any capture, and defers the per-source
    /// limits to the labels tested above.
    @Test func captureToolOwnsScreenEvidenceGuidanceAndSchemasHaveNoMemoryMaintenance() {
        // Wrapped for reading, so compare the guidance as one run of words.
        let guidance = captureScreenTool.guidance
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(guidance.contains("The screenshot is ground truth"))
        #expect(guidance.contains("untrusted reference data"))
        #expect(guidance.contains(
            "Each text source's label says when it was captured and what it can miss."))
        #expect(!guidance.contains("virtualized editors"))
        #expect(!guidance.contains("Use both sources together"))
        #expect(!JarvisPrompts.Coach.system.contains("Accessibility text may extend beyond"))
        #expect(!speakTool(detailEnabled: true).parametersJSON.contains("screenMemory"))
        #expect(!staySilentTool.parametersJSON.contains("screenMemory"))
    }

    @Test func coachPromptRequiresMissingVisibleContextBeforeSpeaking() {
        #expect(JarvisPrompts.Coach.system.contains("Screen gate: before speaking, capture"))
        #expect(JarvisPrompts.Coach.system.contains("absent from the conversation"))
        #expect(JarvisPrompts.Coach.system.contains("This gate applies to either speaker"))
        #expect(JarvisPrompts.Coach.system.contains("Never guess missing content"))
        #expect(JarvisPrompts.Coach.system.contains("one pass\" without the problem"))
    }

    /// OCR line-level claims must come from the image — a live session audit caught the model
    /// "correcting" an already-correct line it had misread from OCR noise. OCR-only sightings turn
    /// into a double-check tip (the overlay is one-way; there's no dialogue to "ask" in).
    @Test func coachPromptGroundsLineLevelClaimsInTheImage() {
        let guidance = captureScreenTool.guidance
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(guidance.contains("The screenshot is ground truth"))
        #expect(guidance.contains("check it in the image"))
        #expect(guidance.contains("suggest double-checking it instead"))
    }

    @Test func coachPromptTreatsFreshCaptureAsSatisfyingScreenGate() {
        #expect(JarvisPrompts.Coach.system.contains("A fresh screenshot or screen text in the current input"))
        #expect(JarvisPrompts.Coach.system.contains("A fresh capture result satisfies the screen gate"))
        #expect(JarvisPrompts.Coach.system.contains("do not capture again"))
        #expect(JarvisPrompts.Coach.system.contains("the same request"))
    }

    @Test func coachPromptRequiresOneActionPerModelResponse() {
        #expect(JarvisPrompts.Coach.system.contains("one action on each model response"))
        #expect(!JarvisPrompts.Coach.system.contains("one tool call each turn"))
    }

    /// Fragment silence applies only to wholly fragmentary fresh speech, never silence probes or
    /// meaningful signals that should continue through the coaching policy.
    @Test func coachPromptScopesFragmentSilence() {
        let prompt = JarvisPrompts.Coach.system.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(prompt.contains("when a non-silence request contains new speech"))
        #expect(prompt.contains("call stay_silent only if all of it is incomplete or likely mistranscribed"))
        #expect(prompt.contains("Help/stuck signals and other meaningful speech bypass this gate"))
        #expect(prompt.contains(
            "If a reply is required despite uncertain transcription, hedge rather than correct it"
        ))
    }

    @Test func coachPromptOrdersDirectRepliesThenFragmentsThenScreenGate() {
        let directReply = JarvisPrompts.Coach.system.range(of: "1. Direct address from \"me\"")
        let fragmentGate = JarvisPrompts.Coach.system.range(of: "2. Fragment gate")
        let screenGate = JarvisPrompts.Coach.system.range(of: "3. Screen gate")
        #expect(directReply != nil)
        #expect(fragmentGate != nil)
        #expect(screenGate != nil)
        if let directReply, let fragmentGate, let screenGate {
            #expect(directReply.lowerBound < fragmentGate.lowerBound)
            #expect(fragmentGate.lowerBound < screenGate.lowerBound)
        }
        #expect(JarvisPrompts.Coach.system.contains("bypass the fragment gate"))
        #expect(JarvisPrompts.Coach.system.contains("continue to the screen gate below"))
    }

    @Test func coachContextCoversTechnicalInterviewFormatsWithoutBrandNarrowing() {
        let modelContext = captureScreenTool.description + JarvisPrompts.Coach.system
        #expect(modelContext.contains("behavioral"))
        #expect(modelContext.contains("system-design"))
        #expect(modelContext.contains("coding"))
        #expect(!modelContext.lowercased().contains("leetcode"))
    }

    /// Interviewer instructions are context for coaching the user, never an invitation for Jarvis
    /// to impersonate the user or claim it performed an unavailable action.
    @Test func coachPromptForbidsRolePlayingAndUnsupportedActionClaims() {
        #expect(JarvisPrompts.Coach.system.contains("Never speak as if you are \"me\""))
        #expect(JarvisPrompts.Coach.system.contains("coach \"me\" in the second person"))
        #expect(JarvisPrompts.Coach.system.contains("it does not share it"))
        #expect(JarvisPrompts.Coach.system.contains("Never claim you opened an app"))
    }

    /// The tip style governs `speak` and travels with it; `speak` is always offered, so this text
    /// still reaches the model in every session.
    @Test func coachPromptHasOneConsistentFullSolutionRule() {
        #expect(speakTool(detailEnabled: true).guidance
            .contains("Give a full solution only when \"me\" explicitly asks"))
        #expect(!speakTool(detailEnabled: true).guidance.contains("never the whole answer"))
        #expect(!JarvisPrompts.Coach.system.contains("never the whole answer"))
    }

    /// Once an approach is underway the tip style prefers a pointed question, but when the
    /// interviewer asks for a better approach the candidate lacks, the tip names it. The rule sits in
    /// the tip style, so a boxless session follows it too.
    @Test func tipStyleNamesTheBetterApproachTheInterviewerAskedFor() {
        let style = speakTool(detailEnabled: false).guidance
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(style.contains("When \"them\" asks for a better approach and \"me\" has not offered one"))
        #expect(style.contains("The shape of an approach is not a full solution."))
    }

    /// Mid-interview "me" is talking to the interviewer, so a rule that waits for "me" to ask Jarvis
    /// why never fires. The need is read from the conversation, and the answer stays short.
    @Test func detailExplanationsAreTriggeredByTheConversationAndStayShort() {
        let detail = speakTool(detailEnabled: true).guidance
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(detail.contains("cannot stop to ask you why"))
        #expect(detail.contains("\"them\" pushes past what \"me\" gave, such as asking for a better approach"))
        #expect(detail.contains("A new question or quiet alone does not show it."))
        #expect(detail.contains("No headings, background, or alternatives."))
        #expect(!detail.contains("only when the user asks you to explain"))
    }

    /// The better approach's sketch is a coding rule: it lives in the skill, ordered so the model
    /// writes the reason and the trace before the pseudo-code rather than the block alone.
    @Test func codingSkillSketchesABetterApproachInOrder() throws {
        let skill = try #require(SkillCatalog.bundled().first { $0.name == "coding" })
        let body = skill.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(body.contains("asks for a better approach than the candidate's and speak offers detail"))
        let reason = try #require(body.range(of: "1. Why it works, in one everyday sentence"))
        let trace = try #require(body.range(of: "2. A one-line trace"))
        let sketch = try #require(body.range(of: "3. Pseudo-code for the whole approach"))
        #expect(reason.lowerBound < trace.lowerBound && trace.lowerBound < sketch.lowerBound)
        #expect(body.contains("A better approach's sketch, above, is the one exception."))
    }

    /// A live session shipped "compare left spine height vs right spine height" — inside the line
    /// budget, but built on a term that appeared nowhere on the user's screen. Tips borrow the
    /// vocabulary already in front of the user; a genuinely necessary new term is glossed, not
    /// dropped, because accuracy outranks brevity.
    @Test func coachPromptGroundsTipVocabularyInWhatTheUserAlreadySees() {
        let prompt = speakTool(detailEnabled: true).guidance
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(prompt.contains("Name things with the words already in front of \"me\""))
        // Either speaker: the interviewer's spoken terms are also in front of the user, and
        // interviewer questions are first-class coaching input.
        #expect(prompt.contains("on the captured screen, or in what either speaker said"))
        // "use", not "introduce": saying "I'm not familiar with X" would otherwise make X a term
        // "me" has said, and so licence reusing it unglossed.
        #expect(prompt.contains("Do not use an unfamiliar term as if it were shared"))
        #expect(prompt.contains("gloss it on first use"))
        #expect(prompt.contains("accuracy outranks brevity"))
        // The old rule only constrained reading effort; "spine" was easy to read and still opaque.
        #expect(prompt.contains("easy to read and understand under pressure"))
    }

    /// Silence is a TOOL now: the prompt must direct the model to stay_silent (never free text),
    /// or a required tool_choice would leave it no sanctioned way to stay quiet.
    @Test func coachPromptDirectsSilenceToTheStaySilentTool() {
        #expect(JarvisPrompts.Coach.system.contains("stay_silent"))
        #expect(!JarvisPrompts.Coach.system.contains("call no tool"))
    }

    // MARK: - ToolInvocation.parse (the shared wire-call mapping)

    @Test func parseMapsEachCoachTool() {
        if case .captureScreen? = ToolInvocation.parse(callId: "c", name: "capture_screen", argumentsJSON: "{}") {} else { Issue.record("capture_screen") }
        if case .staySilent? = ToolInvocation.parse(callId: "c", name: "stay_silent", argumentsJSON: "{}") {} else { Issue.record("stay_silent") }
        guard case .speak(_, let lines, nil)? = ToolInvocation.parse(
            callId: "c", name: "speak", argumentsJSON: #"{"lines":["a","b"]}"#) else {
            Issue.record("speak"); return
        }
        #expect(lines == ["a", "b"])
    }

    @Test func parseRejectsUnknownToolsAndMalformedSpeak() {
        #expect(ToolInvocation.parse(callId: "c", name: "self_destruct", argumentsJSON: "{}") == nil)
        // speak without at least one non-blank line is a malformed call, not an empty spoken turn
        // (a request without `strict` has no Structured Outputs guarantee).
        for args in [#"{}"#, #"{"lines":[]}"#, #"{"lines":["", "  "]}"#, #"{"text":"hi"}"#, "junk"] {
            #expect(ToolInvocation.parse(callId: "c", name: "speak", argumentsJSON: args) == nil,
                    "args=\(args)")
        }
    }

    @Test func parseMapsSearchPrepNotesAndTrimsQuery() {
        guard case .searchPrepNotes(_, let query)? = ToolInvocation.parse(
            callId: "c", name: "search_prep_notes", argumentsJSON: #"{"query":"  rate limiter  "}"#)
        else {
            Issue.record("search_prep_notes"); return
        }
        #expect(query == "rate limiter")
    }

    @Test func parseSearchPrepNotesToleratesAnUnexpectedSiblingField() {
        // A request without `strict` has no Structured Outputs guarantee, so a stray
        // non-string sibling field must not make the whole call fail to parse.
        guard case .searchPrepNotes(_, let query)? = ToolInvocation.parse(
            callId: "c", name: "search_prep_notes",
            argumentsJSON: #"{"query":"rate limiter","extra":{"nested":1}}"#) else {
            Issue.record("search_prep_notes with sibling field"); return
        }
        #expect(query == "rate limiter")
    }

    @Test func parseRejectsMalformedSearchPrepNotes() {
        for args in [#"{}"#, #"{"query":""}"#, #"{"query":"   "}"#, #"{"q":"rate limiter"}"#, "junk"] {
            #expect(ToolInvocation.parse(callId: "c", name: "search_prep_notes", argumentsJSON: args) == nil,
                    "args=\(args)")
        }
    }
}
