import Testing
@testable import JarvisCore

@Suite struct ToolDefsTests {
    @Test func toolNames() {
        #expect(captureScreenTool.name == "capture_screen")
        #expect(speakTool.name == "speak")
        #expect(staySilentTool.name == "stay_silent")
        #expect(coachTools.map(\.name) == ["capture_screen", "speak", "stay_silent"])
    }

    /// `speak` returns the overlay lines pre-split in a strict `lines` array (Structured Outputs),
    /// so the client no longer splits a free-form string.
    @Test func speakToolReturnsStrictLinesArray() {
        #expect(speakTool.parametersJSON.contains("\"lines\""))
        #expect(speakTool.parametersJSON.contains("\"array\""))
        #expect(speakTool.parametersJSON.contains("\"required\""))
        // strict mode requires additionalProperties:false on every object in the schema.
        #expect(speakTool.parametersJSON.contains("\"additionalProperties\":false"))
    }

    @Test func coachToolsDescribeCaptureAndOverlayContracts() {
        #expect(JarvisPrompts.Coach.system.contains("capture_screen"))
        #expect(captureScreenTool.description == JarvisPrompts.Coach.ToolDescription.captureScreen)
        #expect(speakTool.description == JarvisPrompts.Coach.ToolDescription.speak)
        #expect(staySilentTool.description == JarvisPrompts.Coach.ToolDescription.staySilent)
        #expect(captureScreenTool.description.contains("one fresh result satisfies that request"))
        #expect(speakTool.description.contains("up to 3 short standalone overlay lines"))
        #expect(staySilentTool.description.contains("default for unsolicited turns"))
    }

    @Test func coachPromptRequiresMissingVisibleContextBeforeSpeaking() {
        #expect(JarvisPrompts.Coach.system.contains("Screen gate: before speaking, capture"))
        #expect(JarvisPrompts.Coach.system.contains("absent from the conversation"))
        #expect(JarvisPrompts.Coach.system.contains("This gate applies to either speaker"))
        #expect(JarvisPrompts.Coach.system.contains("Never guess missing content"))
        #expect(JarvisPrompts.Coach.system.contains("one pass\" without the problem"))
    }

    /// Line-level claims must come from the image, not OCR — a live session audit caught the model
    /// "correcting" an already-correct line it had misread from OCR noise. OCR-only sightings turn
    /// into a double-check tip (the overlay is one-way; there's no dialogue to "ask" in).
    @Test func coachPromptGroundsLineLevelClaimsInTheImage() {
        #expect(JarvisPrompts.Coach.system.contains("the screenshot image is ground truth"))
        #expect(JarvisPrompts.Coach.system.contains("verify it in the image"))
        #expect(JarvisPrompts.Coach.system.contains("frame the tip as something to double-check"))
    }

    @Test func coachPromptTreatsFreshCaptureAsSatisfyingScreenGate() {
        #expect(JarvisPrompts.Coach.system.contains("A fresh screenshot or OCR in the current input"))
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

    @Test func coachPromptHasOneConsistentFullSolutionRule() {
        #expect(JarvisPrompts.Coach.system.contains("Give a full solution only when \"me\" explicitly asks"))
        #expect(!JarvisPrompts.Coach.system.contains("never the whole answer"))
    }

    /// A live session shipped "compare left spine height vs right spine height" — inside the line
    /// budget, but built on a term that appeared nowhere on the user's screen. Tips borrow the
    /// vocabulary already in front of the user; a genuinely necessary new term is glossed, not
    /// dropped, because accuracy outranks brevity.
    @Test func coachPromptGroundsTipVocabularyInWhatTheUserAlreadySees() {
        let prompt = JarvisPrompts.Coach.system.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
        guard case .speak(_, let lines)? = ToolInvocation.parse(
            callId: "c", name: "speak", argumentsJSON: #"{"lines":["a","b"]}"#) else {
            Issue.record("speak"); return
        }
        #expect(lines == ["a", "b"])
    }

    @Test func parseRejectsUnknownToolsAndMalformedSpeak() {
        #expect(ToolInvocation.parse(callId: "c", name: "self_destruct", argumentsJSON: "{}") == nil)
        // speak without at least one non-blank line is a malformed call, not an empty spoken turn
        // (the CLI protocol has no Structured Outputs guarantee).
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
        // The CLI protocol is free-form prompt text, not a Structured Outputs guarantee — a stray
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
