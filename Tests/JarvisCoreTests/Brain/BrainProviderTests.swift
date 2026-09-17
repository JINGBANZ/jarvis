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
        #expect(BrainProvider.allCases == [.openAI, .codexSubscription, .claudeSubscription])
        #expect(BrainProvider.allCases.filter(\.servedByLocalProxy)
            == [.codexSubscription, .claudeSubscription])
        #expect(BrainProvider.codexSubscription.proxyModelOwner == "openai")
        #expect(BrainProvider.claudeSubscription.proxyModelOwner == "anthropic")
        #expect(BrainProvider.codexSubscription.rawValue == "codex-subscription")
        #expect(BrainProvider.claudeSubscription.rawValue == "claude-subscription")
        #expect(BrainProvider.codexSubscription.displayName == "Codex")
        #expect(BrainProvider.claudeSubscription.displayName == "Claude Code")
    }
}
