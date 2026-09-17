import Foundation

// Design: wiki/settings-window.md#hub
public enum RobotHub {
    public static func state(for inputs: RobotHubInputs) -> RobotHubState {
        var slots: [RobotPart: RobotSlotState] = [:]
        var ready: [Bool] = []
        for part in RobotPart.allCases {
            let summary = summary(of: part, inputs)
            let health = inputs.readiness.map {
                RobotHealth.health(of: part, inputs: inputs, readiness: $0)
            }
            var detail = summary.detail
            var tone = RobotSlotState.Tone.normal
            if part == .brain, let active = inputs.activeTarget {
                detail = liveDetail(activeTarget: active, route: inputs.route)
                tone = .live
            }
            // A problem outranks the live line: it is what the user can act on.
            if case .needsAttention(let reason, _, _)? = health {
                detail = reason
                tone = .attention
            }
            slots[part] = RobotSlotState(
                value: summary.value, detail: detail, tone: tone, level: summary.level, health: health)
            if let health { ready.append(health.isReady) }
        }
        let isLive = inputs.activeTarget != nil
        return RobotHubState(
            slots: slots,
            meter: inputs.readiness == nil ? nil : meter(ready: ready, isLive: isLive),
            isLive: isLive)
    }

    private static func summary(of part: RobotPart, _ inputs: RobotHubInputs) -> RobotPartSummary {
        switch part {
        case .brain:
            RobotPartSummaries.brain(primary: inputs.route.primary, effort: inputs.effort)
        case .ear:
            RobotPartSummaries.ear(inputs.transcription)
        case .eye:
            RobotPartSummaries.eye(
                scope: inputs.screenScope,
                displayIndex: inputs.displayIndex,
                browserTextEnabled: inputs.browserTextEnabled)
        case .mouth:
            RobotPartSummaries.mouth(captionEnabled: inputs.captionEnabled, boxEnabled: inputs.boxEnabled)
        }
    }

    private static func meter(ready: [Bool], isLive: Bool) -> RobotHubMeter {
        let count = ready.filter { $0 }.count
        if isLive {
            return RobotHubMeter(ready: ready, label: "ONLINE · COACHING", tone: .live)
        }
        return count == ready.count
            ? RobotHubMeter(ready: ready, label: "SYSTEMS READY \(count)/\(ready.count)", tone: .normal)
            : RobotHubMeter(ready: ready, label: "NEEDS YOU \(count)/\(ready.count)", tone: .attention)
    }

    private static func liveDetail(activeTarget: BrainTarget, route: BrainRoute) -> String {
        switch route.targets.firstIndex(of: activeTarget) {
        case 0?: "THINKING WITH PRIMARY"
        case let index?: "THINKING WITH FALLBACK \(index)"
        case nil: "THINKING WITH \(activeTarget.provider.displayName.uppercased())"
        }
    }
}
