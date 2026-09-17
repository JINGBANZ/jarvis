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
        case .mouth: mouth(captionEnabled: inputs.captionEnabled, boxEnabled: inputs.boxEnabled)
        }
    }

    private static func brain(_ route: BrainRoute, _ readiness: RobotReadiness) -> RobotPartHealth {
        // Start requires the OpenAI key whenever any target uses the OpenAI API
        // (`TranscriptionProvider.requiredCredentials(for:)`), so a missing key is never skipped.
        if let index = route.targets.firstIndex(where: { $0.provider == .openAI }),
           !readiness.availableCredentials.contains(.openAIAPIKey) {
            let user = index == 0 ? "my primary brain" : "Fallback \(index)"
            return .needsAttention(
                reason: "ADD AN OPENAI KEY",
                advice: "I need an OpenAI key to start, because \(user) uses the OpenAI API. Add it in Connections.",
                fix: .openConnections)
        }
        // Past the key check, only a signed-out subscription can't serve, and the route skips it.
        let canServe = { (target: BrainTarget) in
            !target.provider.servedByLocalProxy
                || !readiness.signedOutSubscriptions.contains(target.provider)
        }
        let primary = route.primary
        guard !canServe(primary) else { return .ready }
        let name = primary.provider.displayName
        return .needsAttention(
            reason: "\(name.uppercased()) IS SIGNED OUT",
            advice: route.fallbackTargets.contains(where: canServe)
                ? "\(name) is signed out. I'll skip it and use the next brain in the route until you sign in again."
                : "No brain in the route can answer right now. Sign in again in Connections, then Start again.",
            fix: .openConnections)
    }

    private static func ear(_ provider: TranscriptionProvider, _ readiness: RobotReadiness) -> RobotPartHealth {
        if let credential = provider.ownCredential, !readiness.availableCredentials.contains(credential) {
            let vendor = credential.vendorName
            let article = "AEIOU".contains(vendor.prefix(1).uppercased()) ? "AN" : "A"
            return .needsAttention(
                reason: "ADD \(article) \(vendor.uppercased()) KEY",
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

    private static func mouth(captionEnabled: Bool, boxEnabled: Bool) -> RobotPartHealth {
        guard captionEnabled || boxEnabled else {
            return .needsAttention(
                reason: "NOTHING WILL SHOW",
                advice: "Both overlays are off, so my hints have nowhere to appear. Switch one on below.",
                fix: nil)
        }
        return .ready
    }
}
