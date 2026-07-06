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

    @Test func coachPromptMentionsCaptureAndBrevity() {
        #expect(coachSystemPrompt.contains("capture_screen"))
        #expect(coachSystemPrompt.contains("3"))
        #expect(coachSystemPrompt.contains("line"))   // brevity is now framed as overlay lines
    }

    /// Silence is a TOOL now: the prompt must direct the model to stay_silent (never free text),
    /// or a required tool_choice would leave it no sanctioned way to stay quiet.
    @Test func coachPromptDirectsSilenceToTheStaySilentTool() {
        #expect(coachSystemPrompt.contains("stay_silent"))
        #expect(!coachSystemPrompt.contains("call no tool"))
    }
}
