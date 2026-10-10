import Foundation

// Design: wiki/settings-window.md#hub
public enum RobotHub {
    public static func state(for inputs: RobotHubInputs) -> RobotHubState {
        var slots: [RobotPart: RobotSlotState] = [:]
        var healths: [RobotPartHealth] = []
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
            if let health, let reason = health.reason {
                detail = reason
                tone = health.tone
            }
            slots[part] = RobotSlotState(
                value: summary.value, detail: detail, tone: tone, level: summary.level, health: health)
            if let health { healths.append(health) }
        }
        let isLive = inputs.activeTarget != nil
        return RobotHubState(
            slots: slots,
            meter: inputs.readiness == nil ? nil : meter(healths: healths, isLive: isLive),
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
            RobotPartSummaries.mouth(fontSize: inputs.boxFontSize)
        }
    }

    private static func meter(healths: [RobotPartHealth], isLive: Bool) -> RobotHubMeter {
        let count = healths.filter(\.isReady).count
        let total = healths.count
        let blocked = healths.contains { $0.tone == .blocked }
        let tone: RobotSlotState.Tone = blocked ? .blocked
            : count < total ? .attention : isLive ? .live : .normal
        let label = isLive ? "ONLINE · COACHING"
            : blocked ? "NOT READY \(count)/\(total)"
            : healths.contains(.checking) ? "CHECKING \(count)/\(total)"
            : count == total ? "SYSTEMS READY \(count)/\(total)" : "NEEDS YOU \(count)/\(total)"
        return RobotHubMeter(signals: healths.map(\.tone), label: label, tone: tone)
    }

    private static func liveDetail(activeTarget: BrainTarget, route: BrainRoute) -> String {
        switch route.targets.firstIndex(of: activeTarget) {
        case 0?: "THINKING WITH PRIMARY"
        case let index?: "THINKING WITH FALLBACK \(index)"
        case nil: "THINKING WITH \(activeTarget.provider.displayName.uppercased())"
        }
    }
}
