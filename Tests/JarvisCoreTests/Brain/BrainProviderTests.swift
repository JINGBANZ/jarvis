import Testing
@testable import JarvisCore

@Suite struct BrainProviderTests {
    /// Every provider today honors `required`, `allowed_tools`, and a forced function, and accepts
    /// every reasoning level, so its request bodies stay exactly what they were.
    @Test func everyCurrentProviderIsProviderEnforcedWithNoFloor() {
        for provider in BrainProvider.allCases {
            #expect(provider.toolChoicePolicy == .providerEnforced)
            #expect(provider.reasoningEffortFloor == nil)
        }
    }
}
