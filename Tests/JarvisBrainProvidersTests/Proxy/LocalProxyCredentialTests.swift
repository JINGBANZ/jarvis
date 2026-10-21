import Foundation
import JarvisCore
import Testing
@testable import JarvisBrainProviders

@Suite struct LocalProxyCredentialTests {
    private func credential(
        _ cooldowns: String, statusMessage: String = "", status: String = "active",
        disabled: Bool = false, unavailable: Bool = false
    ) throws -> LocalProxyCredential {
        let json = #"{"name":"codex-fixture.json","status":"\#(status)","disabled":\#(disabled),"unavailable":\#(unavailable),"status_message":"\#(statusMessage)","cooldowns":\#(cooldowns)}"#
        return try JSONDecoder().decode(LocalProxyCredential.self, from: Data(json.utf8))
    }

    @Test(arguments: ["quota", "transient_error"])
    func aggregateModelCooldownStatusDoesNotBlockTheAccount(reason: String) throws {
        let value = try credential(
            #"[{"scope":"model","model_key":"gpt-6.1-sol","reason":"\#(reason)","remaining_seconds":60}]"#,
            status: "error", unavailable: true)
        #expect(value.unavailability(for: .codexSubscription) == nil)
        #expect(value.modelCooldowns(for: .codexSubscription).count == 1)
    }

    @Test(arguments: ["token expired", " Token Expired ", "invalid_grant", "invalid grant (retrying)"])
    func tokenFailuresStayUnavailableDuringAModelCooldown(message: String) throws {
        let value = try credential(
            #"[{"scope":"model","model_key":"gpt-6.1-sol","reason":"quota","remaining_seconds":60}]"#,
            statusMessage: message, status: "error", unavailable: true)
        #expect(value.unavailability(for: .codexSubscription)?.category == .unavailable)
    }

    @Test func aDisabledAccountStaysUnavailableDuringAModelCooldown() throws {
        let value = try credential(
            #"[{"scope":"model","model_key":"gpt-6.1-sol","reason":"quota","remaining_seconds":60}]"#,
            status: "disabled", disabled: true, unavailable: true)
        #expect(value.unavailability(for: .codexSubscription)?.category == .configuration)
        #expect(value.unavailability(for: .codexSubscription)?.disposition == .permanent)
    }

    @Test(arguments: ["gpt-6.1-sol", " gpt-6.1-sol(high) ", "gpt-6.1-sol()"])
    func modelCooldownUsesTheHelpersCanonicalModelKey(key: String) throws {
        let value = try credential(
            #"[{"scope":"model","model_key":"gpt-6.1-sol","reason":"quota","remaining_seconds":60}]"#)
        let failures = value.modelCooldowns(for: .codexSubscription)
        let target = BrainTarget(provider: .codexSubscription, modelID: "gpt-6.1-sol")
        #expect(failures.count == 1)
        #expect(failures[target]?.category == .quota)
        #expect(failures[target]?.disposition == .temporary)
        #expect(LocalProxyCredential.modelKey(key) == target.modelID)
        #expect(value.unavailability(for: .codexSubscription) == nil)
    }

    @Test(arguments: ["gpt-6.1-sol-preview", "GPT-6.1-sol", "gpt-6.1-sol(high"])
    func modelKeysDoNotUsePrefixOrCaseInsensitiveMatching(key: String) throws {
        let value = try credential(
            #"[{"scope":"model","model_key":"\#(key)","reason":"unavailable","remaining_seconds":60}]"#)
        let target = BrainTarget(provider: .codexSubscription, modelID: "gpt-6.1-sol")
        #expect(value.modelCooldowns(for: .codexSubscription)[target] == nil)
    }

    @Test func aCredentialCooldownAppliesEvenWhenTheAccountReportsActive() throws {
        let value = try credential(
            #"[{"scope":"credential","reason":"credential_quota","remaining_seconds":60}]"#)
        #expect(value.unavailability(for: .codexSubscription)?.category == .quota)
        #expect(value.unavailability(for: .codexSubscription)?.disposition == .temporary)
        #expect(value.modelCooldowns(for: .codexSubscription).isEmpty)
    }

    @Test func aCredentialCooldownTakesPrecedenceOverAModelCooldown() throws {
        let value = try credential(
            #"[{"scope":"credential","reason":"credential_quota","remaining_seconds":60},{"scope":"model","model_key":"gpt-6.1-sol","reason":"quota","remaining_seconds":60}]"#,
            status: "error", unavailable: true)
        #expect(value.unavailability(for: .codexSubscription)?.category == .quota)
        #expect(value.unavailability(for: .codexSubscription)?.identity.errorCode == nil)
    }

    @Test(arguments: ["credential", "model"])
    func rejectedAuthenticationTakesPrecedenceOverCooldowns(scope: String) throws {
        let value = try credential(
            #"[{"scope":"\#(scope)","model_key":"gpt-6.1-sol","reason":"quota","remaining_seconds":60}]"#,
            statusMessage: "unauthorized")
        #expect(value.unavailability(for: .codexSubscription)?.category == .authentication)
        #expect(value.unavailability(for: .codexSubscription)?.disposition == .permanent)
    }

    @Test func anEndedCooldownDoesNotBlockAHealthyAccount() throws {
        let value = try credential(
            #"[{"scope":"credential","reason":"quota","remaining_seconds":0}]"#)
        #expect(value.unavailability(for: .codexSubscription) == nil)
    }
}
