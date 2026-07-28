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
        #expect(captureScreenTool.description.contains("at most once per coaching attempt"))
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
        #expect(coachSystemPrompt.contains("single capture opportunity"))
        #expect(coachSystemPrompt.contains("never call capture_screen again"))
        #expect(coachSystemPrompt.contains("successful or failed"))
    }

    @Test func coachPromptRequiresOneActionPerModelResponse() {
        #expect(coachSystemPrompt.contains("one action on each model response"))
        #expect(!coachSystemPrompt.contains("one tool call each turn"))
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
