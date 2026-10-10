import Foundation
import JarvisCore

/// Only runtime health fields from the helper's credentials list. Token metadata is never decoded.
struct LocalProxyCredential: Decodable, Sendable {
    let name: String
    let auth_index: String?
    let provider: String?
    let type: String?
    let status: String?
    let status_message: String?
    let disabled: Bool?
    let unavailable: Bool?
    let cooldowns: [Cooldown]?

    struct Cooldown: Decodable, Sendable {
        let scope: String
        let reason: String
        let remaining_seconds: Int
    }

    var requiresSignIn: Bool {
        let message = status_message?.lowercased() ?? ""
        return message == "unauthorized" || message == "unauthorized (refresh token invalid)"
            || message == "disabled (invalid grant)" || message.contains("refresh_token_invalidated")
    }

    var needsRefresh: Bool {
        guard !requiresSignIn, disabled == false, unavailable == true, status == "error",
              !(cooldowns ?? []).contains(where: { $0.remaining_seconds > 0 }) else { return false }
        return status_message == "token expired" || status_message == "" || status_message == nil
    }

    func unavailability(for provider: BrainProvider) -> ProviderFailure? {
        if requiresSignIn {
            return failure(provider, category: .authentication, disposition: .permanent,
                           code: "unauthorized", message: "Your session has ended; sign in again in Settings → Connections.")
        }
        if disabled == true || status == "disabled" {
            return failure(provider, category: .configuration, disposition: .permanent,
                           message: "The saved subscription is disabled.")
        }
        guard status != nil, disabled != nil, unavailable != nil else {
            return failure(provider, category: .unavailable,
                           message: "The sign-in service couldn't determine credential health. Try again.")
        }
        if status == "active", unavailable == false { return nil }
        if let cooldown = cooldowns?.first(where: { $0.remaining_seconds > 0 && $0.scope == "credential" }) {
            return failure(provider, category: ["quota", "credential_quota"].contains(cooldown.reason) ? .quota : .unavailable,
                           message: "The subscription is temporarily unavailable. Try again after its cooldown.")
        }
        return failure(provider, category: .unavailable,
                       message: needsRefresh ? "The saved access token has expired; refresh hasn't succeeded. Try again."
                           : "The subscription is temporarily unavailable. Try again.")
    }

    private func failure(
        _ provider: BrainProvider, category: ProviderFailure.Category,
        disposition: ProviderFailure.Disposition = .temporary, code: String? = nil, message: String
    ) -> ProviderFailure {
        ProviderFailure(source: .brain(provider), stage: .process, category: category,
                        disposition: disposition, identity: .init(errorCode: code), message: message)
    }
}
