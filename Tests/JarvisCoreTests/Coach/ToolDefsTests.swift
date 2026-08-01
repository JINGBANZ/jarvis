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
        #expect(coachSystemPrompt.contains("capture_screen"))
        #expect(captureScreenTool.description.contains("one fresh result satisfies that request"))
        #expect(speakTool.description.contains("up to 3 short standalone overlay lines"))
        #expect(staySilentTool.description.contains("default for unsolicited turns"))
    }

    @Test func coachPromptRequiresMissingVisibleContextBeforeSpeaking() {
        #expect(coachSystemPrompt.contains("Screen gate: before speaking, capture"))
        #expect(coachSystemPrompt.contains("absent from the conversation"))
        #expect(coachSystemPrompt.contains("This gate applies to either speaker"))
        #expect(coachSystemPrompt.contains("Never guess missing content"))
        #expect(coachSystemPrompt.contains("one pass\" without the problem"))
    }

    /// Line-level claims must come from the image, not OCR — a live session audit caught the model
    /// "correcting" an already-correct line it had misread from OCR noise. OCR-only sightings turn
    /// into a double-check tip (the overlay is one-way; there's no dialogue to "ask" in).
    @Test func coachPromptGroundsLineLevelClaimsInTheImage() {
        #expect(coachSystemPrompt.contains("the screenshot image is ground truth"))
        #expect(coachSystemPrompt.contains("verify it in the image"))
        #expect(coachSystemPrompt.contains("frame the tip as something to double-check"))
    }

    @Test func coachPromptTreatsFreshCaptureAsSatisfyingScreenGate() {
        #expect(coachSystemPrompt.contains("A fresh screenshot or OCR in the current input"))
        #expect(coachSystemPrompt.contains("A fresh capture result satisfies the screen gate"))
        #expect(coachSystemPrompt.contains("do not capture again"))
        #expect(coachSystemPrompt.contains("the same request"))
    }

    @Test func coachPromptRequiresOneActionPerModelResponse() {
        #expect(coachSystemPrompt.contains("one action on each model response"))
        #expect(!coachSystemPrompt.contains("one tool call each turn"))
    }

    /// Short fragments and transcription noise should not create unsolicited overlay chatter, while
    /// substantive speech and explicit stuck signals still carry enough interview signal to coach.
    @Test func coachPromptDefaultsFragmentsAndASRGarbleToSilence() {
        let prompt = coachSystemPrompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(prompt.contains(
            "the entire fresh delta consists of short, question-free fragments or likely ASR garble"
        ))
        #expect(prompt.contains(
            "explicit help request or stuck signal, correction, requirement, or technical fact"
        ))
        #expect(prompt.contains("bypass this gate and continue through the remaining policy"))
        #expect(coachSystemPrompt.contains(
            "A likely transcription mistake is not itself a coaching opportunity"
        ))
        #expect(coachSystemPrompt.contains("do not correct its wording"))
        #expect(coachSystemPrompt.contains("Wait for more speech"))
    }

    @Test func coachPromptLimitsFragmentGateToFreshSpeech() {
        let prompt = coachSystemPrompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(prompt.contains("inspect only the final user text block"))
        #expect(prompt.contains("ignore every earlier user block in history"))
        #expect(prompt.contains(
            "apply this gate only when that final block includes \"New since last turn\""
        ))
        #expect(prompt.contains("Evaluate all newly delivered speech in that block"))
        #expect(prompt.contains("not only its last line"))
        #expect(prompt.contains("A final user block with no \"New since last turn\""))
        #expect(prompt.contains("the newest historical speech was fragmentary"))
    }

    @Test func coachPromptLetsSilenceWakeUpsBypassUnsentFiller() {
        let prompt = coachSystemPrompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(prompt.contains(
            "If the final block includes a \"(no speech for ...)\" marker, bypass this gate"
        ))
        #expect(prompt.contains("even when unsent speech rides along under \"New since last turn\""))
    }

    @Test func coachPromptOrdersDirectRepliesThenFragmentsThenScreenGate() {
        let directReply = coachSystemPrompt.range(of: "1. Direct address from \"me\"")
        let fragmentGate = coachSystemPrompt.range(of: "2. Fragment gate")
        let screenGate = coachSystemPrompt.range(of: "3. Screen gate")
        #expect(directReply != nil)
        #expect(fragmentGate != nil)
        #expect(screenGate != nil)
        if let directReply, let fragmentGate, let screenGate {
            #expect(directReply.lowerBound < fragmentGate.lowerBound)
            #expect(fragmentGate.lowerBound < screenGate.lowerBound)
        }
        #expect(coachSystemPrompt.contains("continue to the screen gate below"))
        #expect(coachSystemPrompt.contains("A direct reply required by rule 1 bypasses this gate"))
        #expect(coachSystemPrompt.contains(
            "If a direct reply is required, hedge your interpretation instead"
        ))
    }

    @Test func coachContextCoversTechnicalInterviewFormatsWithoutBrandNarrowing() {
        let modelContext = captureScreenTool.description + coachSystemPrompt
        #expect(modelContext.contains("behavioral"))
        #expect(modelContext.contains("system-design"))
        #expect(modelContext.contains("coding"))
        #expect(!modelContext.lowercased().contains("leetcode"))
    }

    @Test func coachPromptHasOneConsistentFullSolutionRule() {
        #expect(coachSystemPrompt.contains("Give a full solution only when \"me\" explicitly asks"))
        #expect(!coachSystemPrompt.contains("never the whole answer"))
    }

    /// Silence is a TOOL now: the prompt must direct the model to stay_silent (never free text),
    /// or a required tool_choice would leave it no sanctioned way to stay quiet.
    @Test func coachPromptDirectsSilenceToTheStaySilentTool() {
        #expect(coachSystemPrompt.contains("stay_silent"))
        #expect(!coachSystemPrompt.contains("call no tool"))
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
}
