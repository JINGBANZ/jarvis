import Testing
@testable import JarvisCore

@Suite struct BrainProviderTests {
    /// Claude Code can neither force nor narrow a tool call, and rejects disabled reasoning.
    @Test func onlyTheClaudeSubscriptionFiltersToolsAndFloorsReasoning() {
        for provider in BrainProvider.allCases {
            #expect(provider.toolChoicePolicy
                == (provider == .claudeSubscription ? .filteredAuto : .providerEnforced))
            #expect(provider.reasoningEffortFloor == (provider == .claudeSubscription ? .low : nil))
        }
    }

    @Test func subscriptionsAreServedByTheBundledHelper() {
        #expect(BrainProvider.allCases == [.openAI, .codexSubscription, .claudeSubscription, .gemini])
        #expect(BrainProvider.allCases.filter(\.servedByLocalProxy)
            == [.codexSubscription, .claudeSubscription])
        #expect(BrainProvider.codexSubscription.proxyModelOwner == "openai")
        #expect(BrainProvider.claudeSubscription.proxyModelOwner == "anthropic")
        #expect(BrainProvider.codexSubscription.rawValue == "codex-subscription")
        #expect(BrainProvider.claudeSubscription.rawValue == "claude-subscription")
        #expect(BrainProvider.codexSubscription.displayName == "Codex")
        #expect(BrainProvider.claudeSubscription.displayName == "Claude Code")
    }

    @Test func eachProviderHasOneDescriptor() {
        #expect(BrainProviderDescriptor.openAIResponsesEndpoint.absoluteString
            == "https://api.openai.com/v1/responses")
        #expect(BrainProvider.openAI.descriptor.access == .apiKey(
            credential: .openAIAPIKey,
            endpoint: BrainProviderDescriptor.openAIResponsesEndpoint, auth: .bearer))
        #expect(BrainProvider.codexSubscription.descriptor.access == .localProxy(
            modelOwner: "openai", loginFlag: "-codex-login", accountFilePrefix: "codex-"))
        #expect(BrainProvider.claudeSubscription.descriptor.access == .localProxy(
            modelOwner: "anthropic", loginFlag: "-claude-login", accountFilePrefix: "claude-"))
        for provider in [BrainProvider.openAI, .codexSubscription, .claudeSubscription] {
            #expect(provider.descriptor.wire == .responses)
            #expect(provider.descriptor.failureTable == .openAI)
            #expect(provider.descriptor.auth == .bearer)
            #expect(provider.displayName == provider.descriptor.displayName)
            #expect(provider.credential == (provider == .openAI ? .openAIAPIKey : nil))
        }
    }

    @Test func geminiIsAKeyedTargetOnTheInteractionsAPI() {
        let gemini = BrainProvider.gemini
        #expect(gemini.rawValue == "gemini")
        #expect(gemini.displayName == "Gemini API")
        #expect(BrainProviderDescriptor.geminiInteractionsEndpoint.absoluteString
            == "https://generativelanguage.googleapis.com/v1/interactions")
        #expect(gemini.descriptor.access == .apiKey(
            credential: .geminiAPIKey,
            endpoint: BrainProviderDescriptor.geminiInteractionsEndpoint, auth: .googAPIKey))
        #expect(gemini.descriptor.wire == .interactions)
        #expect(gemini.descriptor.failureTable == .gemini)
        #expect(gemini.toolChoicePolicy == .providerEnforced)
        #expect(gemini.reasoningEffortFloor == nil)
        #expect(!gemini.servedByLocalProxy)
        #expect(Defaults.Brain.modelKey(for: .gemini) == "brain.model.gemini")
    }
}
