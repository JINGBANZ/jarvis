import Testing
@testable import JarvisCore

@Suite struct BrainProviderTests {
    /// Only the Claude subscription can neither force nor narrow a call, and rejects disabled
    /// reasoning; every other provider's request bodies keep provider-enforced choices.
    @Test func onlyTheClaudeSubscriptionFiltersToolsAndFloorsReasoning() {
        for provider in BrainProvider.allCases {
            #expect(provider.toolChoicePolicy
                == (provider == .claudeSubscription ? .filteredAuto : .providerEnforced))
            #expect(provider.reasoningEffortFloor == (provider == .claudeSubscription ? .low : nil))
        }
    }

    @Test func subscriptionsAreServedByTheBundledHelper() {
        #expect(BrainProvider.allCases == [.openAI, .codexSubscription, .claudeSubscription])
        #expect(BrainProvider.allCases.filter(\.servedByLocalProxy)
            == [.codexSubscription, .claudeSubscription])
        #expect(BrainProvider.codexSubscription.proxyModelOwner == "openai")
        #expect(BrainProvider.claudeSubscription.proxyModelOwner == "anthropic")
        #expect(BrainProvider.codexSubscription.rawValue == "codex-subscription")
        #expect(BrainProvider.claudeSubscription.rawValue == "claude-subscription")
        #expect(BrainProvider.codexSubscription.displayName == "Codex subscription")
        #expect(BrainProvider.claudeSubscription.displayName == "Claude subscription")
    }
}
