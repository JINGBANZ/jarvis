import Foundation

// Design: wiki/architecture.md#onboarding
/// A refused key is never saved, so it can't make a later launch skip the step. A check the
/// provider couldn't answer is no evidence against the key, so the user may keep it anyway.
public struct OnboardingAPIKeyStep: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case editing
        case checking
        case refused(String)
        case unverified(String)
        case saveFailed
    }

    public enum Effect: Sendable, Equatable {
        case check(Credential, key: String)
        case save(Credential, key: String)
    }

    public enum Tone: Sendable, Equatable {
        case plain
        case warning
    }

    public private(set) var credential: Credential
    public private(set) var key = ""
    public private(set) var phase = Phase.editing

    public init(credential: Credential) {
        self.credential = credential
    }

    public var canContinue: Bool {
        !key.isEmpty && phase != .checking
    }

    public var primaryTitle: String {
        switch phase {
        case .checking: "Checking…"
        case .unverified: "Continue Anyway"
        case .editing, .refused, .saveFailed: "Continue"
        }
    }

    public var note: String {
        switch phase {
        case .editing: "I keep it on this Mac, in a file only you can read."
        case .checking: "Checking the key with \(credential.vendorName)…"
        case .refused(let reason), .unverified(let reason): reason
        case .saveFailed: "I couldn’t save the key. Try again."
        }
    }

    public var noteTone: Tone {
        switch phase {
        case .editing, .checking: .plain
        case .refused, .unverified, .saveFailed: .warning
        }
    }

    /// Ignored while checking, so a verdict always describes the key and vendor on screen.
    public mutating func select(_ credential: Credential) {
        guard phase != .checking, credential != self.credential else { return }
        self.credential = credential
        phase = .editing
    }

    public mutating func edit(_ text: String) {
        guard phase != .checking else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != key else { return }
        key = trimmed
        phase = .editing
    }

    public mutating func continuePressed() -> Effect? {
        guard canContinue else { return nil }
        switch phase {
        case .unverified, .saveFailed:
            // The key was kept or already accepted, so only the write is retried.
            return .save(credential, key: key)
        case .editing, .checking, .refused:
            phase = .checking
            return .check(credential, key: key)
        }
    }

    /// The caller performs a returned save and reports `saveFailed()` if writing fails.
    public mutating func receive(_ verdict: CredentialCheck.Verdict) -> Effect? {
        guard phase == .checking else { return nil }
        switch verdict {
        case .accepted:
            return .save(credential, key: key)
        case .rejected:
            phase = .refused(CredentialCheck.statusText(verdict, for: credential))
        case .inconclusive:
            phase = .unverified(CredentialCheck.statusText(verdict, for: credential))
        }
        return nil
    }

    public mutating func saveFailed() {
        phase = .saveFailed
    }
}
