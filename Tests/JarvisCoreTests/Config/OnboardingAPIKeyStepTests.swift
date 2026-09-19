import Foundation
import Testing
@testable import JarvisCore

@Suite struct OnboardingAPIKeyStepTests {
    private func refused() throws -> CredentialCheck.Verdict {
        let body = try JSONSerialization.data(withJSONObject: [
            "error": ["code": "invalid_api_key", "type": "invalid_request_error",
                      "message": "Incorrect API key provided."],
        ])
        return CredentialCheck.verdict(for: .openAIAPIKey, httpStatus: 401, body: body)
    }

    private let unanswered = CredentialCheck.verdict(for: .openAIAPIKey, httpStatus: 503, body: nil)

    private func typed(_ key: String = "sk-test") -> OnboardingAPIKeyStep {
        var step = OnboardingAPIKeyStep(credential: .openAIAPIKey)
        step.edit(key)
        return step
    }

    @Test func anEmptyKeyCannotContinue() {
        var step = OnboardingAPIKeyStep(credential: .openAIAPIKey)
        step.edit("   ")
        let effect = step.continuePressed()
        #expect(effect == nil)
        #expect(!step.canContinue)
        #expect(step.note == "I keep it on this Mac, in a file only you can read.")
        #expect(step.noteTone == .plain)
    }

    @Test func continueChecksTheTrimmedKeyBeforeSaving() {
        var step = typed("  sk-test \n")
        let effect = step.continuePressed()
        #expect(effect == .check(.openAIAPIKey, key: "sk-test"))
        #expect(step.phase == .checking)
        #expect(step.primaryTitle == "Checking…")
        #expect(step.note == "Checking the key with OpenAI…")
        #expect(!step.canContinue)
    }

    @Test func anAcceptedKeyIsSaved() {
        var step = typed()
        _ = step.continuePressed()
        let effect = step.receive(.accepted)
        #expect(effect == .save(.openAIAPIKey, key: "sk-test"))
    }

    @Test func aRefusedKeyIsNeverSaved() throws {
        var step = typed()
        _ = step.continuePressed()
        let verdict = try refused()
        let effect = step.receive(verdict)
        #expect(effect == nil)
        guard case .refused = step.phase else {
            Issue.record("expected a refusal"); return
        }
        #expect(step.noteTone == .warning)
        #expect(step.note.hasPrefix("OpenAI refused the key"))
        #expect(step.primaryTitle == "Continue")
        let retry = step.continuePressed()
        #expect(retry == .check(.openAIAPIKey, key: "sk-test"))
    }

    @Test func aKeyTheProviderCouldNotCheckCanBeKeptAnyway() {
        var step = typed()
        _ = step.continuePressed()
        let effect = step.receive(unanswered)
        #expect(effect == nil)
        #expect(step.primaryTitle == "Continue Anyway")
        #expect(step.note == "I couldn't check the key with OpenAI (HTTP 503).")
        #expect(step.noteTone == .warning)
        let keep = step.continuePressed()
        #expect(keep == .save(.openAIAPIKey, key: "sk-test"))
    }

    @Test func editingTheKeyClearsAVerdict() {
        var step = typed()
        _ = step.continuePressed()
        _ = step.receive(unanswered)
        step.edit("sk-other")
        #expect(step.phase == .editing)
        let effect = step.continuePressed()
        #expect(effect == .check(.openAIAPIKey, key: "sk-other"))
    }

    @Test func pickingTheOtherVendorClearsAVerdictAndKeepsTheKey() throws {
        var step = typed()
        _ = step.continuePressed()
        _ = step.receive(try refused())
        step.select(.geminiAPIKey)
        #expect(step.phase == .editing)
        #expect(step.key == "sk-test")
        let effect = step.continuePressed()
        #expect(effect == .check(.geminiAPIKey, key: "sk-test"))
    }

    @Test func inputIsIgnoredWhileChecking() {
        var step = typed()
        _ = step.continuePressed()
        step.edit("sk-other")
        step.select(.geminiAPIKey)
        #expect(step.key == "sk-test")
        #expect(step.credential == .openAIAPIKey)
        let effect = step.continuePressed()
        #expect(effect == nil)
    }

    @Test func aFailedSaveAsksToTryAgain() {
        var step = typed()
        _ = step.continuePressed()
        _ = step.receive(.accepted)
        step.saveFailed()
        #expect(step.note == "I couldn’t save the key. Try again.")
        #expect(step.noteTone == .warning)
        let effect = step.continuePressed()
        #expect(effect == .save(.openAIAPIKey, key: "sk-test"))
    }

    @Test func aVerdictWhileNotCheckingIsIgnored() {
        var step = typed()
        let effect = step.receive(.accepted)
        #expect(effect == nil)
        #expect(step.phase == .editing)
    }
}
