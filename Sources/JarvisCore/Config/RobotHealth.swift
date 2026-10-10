import Foundation

/// Judges settings the way a Start would meet them, naming only what Settings can fix or explain.
public enum RobotHealth {
    public static func health(
        of part: RobotPart, inputs: RobotHubInputs, readiness: RobotReadiness
    ) -> RobotPartHealth {
        switch part {
        case .brain: brain(inputs.route, readiness)
        case .ear: ear(inputs.transcription.provider, readiness)
        case .eye: eye(readiness)
        case .mouth: .ready
        }
    }

    private static func brain(_ route: BrainRoute, _ readiness: RobotReadiness) -> RobotPartHealth {
        switch connection(route.primary, readiness) {
        case .ready: return .ready
        case .checking: return .checking
        case .unavailable(let failure):
            if let fallback = route.fallbackTargets.first(where: { connection($0, readiness) == .ready }) {
                return .needsAttention(
                    reason: "PRIMARY UNAVAILABLE",
                    advice: failure.activitySentence + " I'll use \(fallback.provider.displayName) until the primary is available.",
                    fix: .openConnections)
            }
            if route.fallbackTargets.contains(where: { connection($0, readiness) == .checking }) {
                return .checking
            }
            return .blocked(
                reason: "NO BRAIN AVAILABLE",
                advice: failure.activitySentence + " No configured fallback is available.",
                fix: .openConnections)
        }
    }

    private static func connection(_ target: BrainTarget, _ readiness: RobotReadiness) -> RobotReadiness.ConnectionHealth {
        if let failure = target.credentialFailure(available: readiness.availableCredentials) {
            return .unavailable(failure)
        }
        guard target.provider.servedByLocalProxy else { return .ready }
        return readiness.subscriptions[target.provider] ?? .checking
    }

    private static func ear(_ provider: TranscriptionProvider, _ readiness: RobotReadiness) -> RobotPartHealth {
        if let credential = provider.ownCredential, !readiness.availableCredentials.contains(credential) {
            let vendor = credential.vendorName
            return .needsAttention(
                reason: "ADD \(article(for: vendor).uppercased()) \(vendor.uppercased()) KEY",
                advice: "I need your \(vendor) key to hear the conversation. Add it in Connections.",
                fix: .openConnections)
        }
        guard readiness.grantedPermissions.contains(.microphone) else {
            return .needsAttention(
                reason: "MICROPHONE IS OFF",
                advice: "Microphone access is off. Turn it on in System Settings, Privacy & Security.",
                fix: nil)
        }
        return .ready
    }

    private static func eye(_ readiness: RobotReadiness) -> RobotPartHealth {
        guard readiness.grantedPermissions.contains(.screenRecording) else {
            return .needsAttention(
                reason: "SCREEN RECORDING IS OFF",
                advice: "Screen Recording is off, so I can't see your screen. "
                    + "Turn it on in System Settings, Privacy & Security, then reopen me.",
                fix: nil)
        }
        return .ready
    }

    private static func article(for vendor: String) -> String {
        "AEIOU".contains(vendor.prefix(1).uppercased()) ? "an" : "a"
    }
}
