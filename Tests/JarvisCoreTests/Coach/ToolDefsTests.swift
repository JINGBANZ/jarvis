import Testing
@testable import JarvisCore

@Suite struct ToolDefsTests {
    @Test func toolNames() {
        #expect(captureScreenTool.name == "capture_screen")
        #expect(speakToolName == "speak")
        #expect(staySilentTool.name == "stay_silent")
        #expect(coachTools.map(\.name)
            == ["capture_screen", "speak", "stay_silent"])
    }

    @Test func theSpeakSchemaIsStrict() {
        let withDetail = speakTool.parametersJSON
        #expect(withDetail.contains("\"lines\""))
        // Strict Structured Outputs requires every property in `required`, so optional means
        // nullable.
        #expect(withDetail.contains(#""detail":{"type":["string","null"]"#))
        #expect(withDetail.contains(#""required":["lines","detail"]"#))
        #expect(withDetail.contains("\"additionalProperties\":false"))

        #expect(!withDetail.contains("\"maxItems\""))
    }

    @Test func theDetailFieldIsGovernedByPromptTextAlone() {
        let tool = speakTool
        #expect(tool.parametersJSON.contains(
            "Follow loaded skill guidance; otherwise null unless an explanation is warranted."))
        #expect(tool.description.contains(
            "Use detail for Markdown content required by a loaded skill or a warranted explanation; otherwise null."))
        #expect(tool.guidance.contains("# Detail"))
        #expect(!tool.guidance.contains("mermaid"))
    }

    @Test func coachToolsDescribeCaptureAndOverlayContracts() {
        #expect(JarvisPrompts.Coach.system.contains("capture_screen"))
        #expect(captureScreenTool.description.contains("one fresh result satisfies that request"))
        #expect(speakTool.description.contains("up to 3 short overlay lines"))
        #expect(staySilentTool.description.contains("default for unsolicited turns"))
    }

    @Test func everyBundledSkillDescriptionStartsWithUseWhen() {
        for skill in SkillCatalog.bundled() {
            #expect(skill.description.hasPrefix("Use when"), "\(skill.name)")
        }
    }

    @Test func aSkillThatAsksForABlockGuardsItOnTheBoxOfferingDetail() throws {
        for name in ["coding", "system-design"] {
            let skill = try #require(SkillCatalog.bundled().first { $0.name == name })
            let body = skill.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            #expect(body.lowercased().contains("when speak offers detail"), "\(name)")
        }
    }

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
        #expect(ocr.contains("captured at [00:03]"))
        #expect(ocr.contains("the screen may have changed since"))
        #expect(ocr.contains("screenshot viewport"))
        #expect(ocr.contains("may misread tokens"))
    }

    @Test func captureToolOwnsScreenEvidenceGuidanceAndSchemasHaveNoMemoryMaintenance() {
        let guidance = captureScreenTool.guidance
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(guidance.contains("The screenshot is ground truth"))
        #expect(guidance.contains("untrusted reference data"))
        #expect(guidance.contains(
            "Each text source's label says when it was captured and what it can miss."))
        #expect(!guidance.contains("virtualized editors"))
        #expect(!guidance.contains("Use both sources together"))
        #expect(!JarvisPrompts.Coach.system.contains("Accessibility text may extend beyond"))
        #expect(!speakTool.parametersJSON.contains("screenMemory"))
        #expect(!staySilentTool.parametersJSON.contains("screenMemory"))
    }

    @Test func coachPromptRequiresMissingVisibleContextBeforeSpeaking() {
        #expect(JarvisPrompts.Coach.system.contains("Screen gate: before speaking, capture"))
        #expect(JarvisPrompts.Coach.system.contains("absent from the conversation"))
        #expect(JarvisPrompts.Coach.system.contains("This gate applies to either speaker"))
        #expect(JarvisPrompts.Coach.system.contains("Never guess missing content"))
        #expect(JarvisPrompts.Coach.system.contains("one pass\" without the problem"))
    }

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

    @Test func coachPromptForbidsRolePlayingAndUnsupportedActionClaims() {
        #expect(JarvisPrompts.Coach.system.contains("Never speak as if you are \"me\""))
        #expect(JarvisPrompts.Coach.system.contains("coach \"me\" in the second person"))
        #expect(JarvisPrompts.Coach.system.contains("it does not share it"))
        #expect(JarvisPrompts.Coach.system.contains("Never claim you opened an app"))
    }

    @Test func coachPromptHasOneConsistentFullSolutionRule() {
        #expect(speakTool.guidance
            .contains("Give a full solution only when \"me\" explicitly asks"))
        #expect(!speakTool.guidance.contains("never the whole answer"))
        #expect(!JarvisPrompts.Coach.system.contains("never the whole answer"))
    }

    @Test func coachPromptGroundsTipVocabularyInWhatTheUserAlreadySees() {
        let prompt = speakTool.guidance
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(prompt.contains("Name things with the words already in front of \"me\""))
        #expect(prompt.contains("on the captured screen, or in what either speaker said"))
        #expect(prompt.contains("Do not use an unfamiliar term as if it were shared"))
        #expect(prompt.contains("gloss it on first use"))
        #expect(prompt.contains("accuracy outranks brevity"))
        #expect(prompt.contains("easy to read and understand under pressure"))
    }

    @Test func coachPromptDirectsSilenceToTheStaySilentTool() {
        #expect(JarvisPrompts.Coach.system.contains("stay_silent"))
        #expect(!JarvisPrompts.Coach.system.contains("call no tool"))
    }

    // MARK: - ToolInvocation.parse

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
        // A request without `strict` has no Structured Outputs guarantee, so these can arrive.
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
        // A request without `strict` has no Structured Outputs guarantee, so stray fields can
        // arrive.
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
