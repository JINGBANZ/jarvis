import Foundation

// Design: wiki/settings-window.md#connections
public struct SubscriptionConnectionState: Sendable, Equatable {
    public enum Action: Sendable {
        case signIn, signOut, retry, cancelSignIn

        public var title: String {
            switch self {
            case .signIn: "Sign in"
            case .signOut: "Sign out"
            case .retry: "Try again"
            case .cancelSignIn: "Cancel"
            }
        }
    }

    public enum Operation: Sendable {
        case signingIn, signingOut, retrying
    }

    public enum Tone: Sendable {
        case neutral, ready, attention
    }

    public struct Button: Sendable, Equatable {
        public let action: Action
        public let title: String
        public let isEnabled: Bool

        public init(_ action: Action, title: String? = nil, isEnabled: Bool = true) {
            self.action = action
            self.title = title ?? action.title
            self.isEnabled = isEnabled
        }
    }

    public let detail: String
    public let tone: Tone
    public let buttons: [Button]

    public init(
        provider: BrainProvider, savedAccountCount: Int, accountDescription: String? = nil,
        health: BrainRouteAvailability.ConnectionHealth, operation: Operation? = nil,
        retryAvailable: Bool = true, accountActionsAvailable: Bool = true, actionFailure: String? = nil
    ) {
        let detail: String
        let tone: Tone
        let buttons: [Button]
        switch operation {
        case .signingIn:
            detail = "Signing in. Finish in your browser."
            tone = .neutral
            buttons = [Button(.cancelSignIn)]
        case .signingOut:
            detail = "Signing out…"
            tone = .neutral
            buttons = [Button(.signOut, title: "Signing out…", isEnabled: false)]
        case .retrying:
            detail = Self.failureDetail(health) ?? "Checking…"
            tone = .attention
            buttons = [Button(.retry, title: "Trying again…", isEnabled: false)]
                + (savedAccountCount > 0 ? [Button(.signOut, isEnabled: false)] : [])
        case nil:
            if savedAccountCount == 0 {
                let account = provider == .codexSubscription ? "ChatGPT" : "Claude"
                if case .unavailable(let failure) = health, failure.category != .authentication {
                    detail = Self.failureDetail(health) ?? failure.activitySentenceWithoutAdvice
                    tone = .attention
                } else {
                    detail = "Signed out. Signs in with your \(account) account."
                    tone = .neutral
                }
                buttons = [Button(.signIn, isEnabled: accountActionsAvailable)]
            } else if savedAccountCount > 1 {
                detail = "Multiple saved accounts. Only one subscription account is supported."
                tone = .attention
                buttons = [Button(.signOut, isEnabled: accountActionsAvailable)]
            } else {
                switch health {
                case .checking:
                    detail = "Checking…"
                    tone = .neutral
                    buttons = [Button(.signOut, isEnabled: accountActionsAvailable)]
                case .ready:
                    detail = ["Signed in", accountDescription].compactMap { $0 }.joined(separator: " · ")
                    tone = .ready
                    buttons = [Button(.signOut, isEnabled: accountActionsAvailable)]
                case .unavailable(let failure):
                    detail = Self.failureDetail(health) ?? failure.activitySentenceWithoutAdvice
                    tone = .attention
                    if failure.disposition == .temporary {
                        buttons = [Button(.retry, isEnabled: retryAvailable),
                                   Button(.signOut, isEnabled: accountActionsAvailable)]
                    } else {
                        buttons = [Button(failure.category == .authentication ? .signIn : .signOut,
                                          isEnabled: accountActionsAvailable)]
                    }
                }
            }
        }
        self.detail = actionFailure ?? detail
        self.tone = actionFailure == nil ? tone : .attention
        self.buttons = buttons
    }

    private static func failureDetail(_ health: BrainRouteAvailability.ConnectionHealth) -> String? {
        guard case .unavailable(let failure) = health else { return nil }
        let detail = failure.errorDescription ?? ""
        return detail.isEmpty ? failure.activitySentenceWithoutAdvice : detail
    }
}
