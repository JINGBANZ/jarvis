import Testing
@testable import JarvisCore

@Suite struct ToolDefsTests {
    @Test func toolNames() {
        #expect(captureScreenTool.name == "capture_screen")
        #expect(speakTool.name == "speak")
    }

    @Test func speakToolRequiresText() {
        #expect(speakTool.parametersJSON.contains("\"text\""))
        #expect(speakTool.parametersJSON.contains("\"required\""))
    }

    @Test func coachPromptMentionsCaptureAndBrevity() {
        #expect(coachSystemPrompt.contains("capture_screen"))
        #expect(coachSystemPrompt.contains("3"))
    }
}
