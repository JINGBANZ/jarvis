import Foundation
import Testing

/// One scenario's results lines: `<case> <pass|fail|note|skipped> [detail]`, plus `time` lines.
///
/// `pass` and `fail` come from `#expect`, labelled with the case ID so a failure names its case.
/// `note` records what the model chose where the outcome is the model's to decide; it never fails
/// the run, and no assertion is ever turned into a note to make a run pass.
struct LiveE2EResults {
    typealias Check = (passed: Bool, label: String)

    let scenario: String
    private(set) var lines: [String] = []
    private(set) var hasFailure = false

    init(scenario: String) {
        self.scenario = scenario
    }

    mutating func check(
        _ caseID: String, _ checks: [Check], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let failed = checks.filter { !$0.passed }
        for check in failed {
            #expect(Bool(false), Comment(rawValue: "\(caseID) [\(scenario)]: \(check.label)"),
                    sourceLocation: sourceLocation)
        }
        if failed.isEmpty {
            lines.append("\(caseID) pass \(scenario)")
        } else {
            hasFailure = true
            lines.append("\(caseID) fail \(scenario): "
                + failed.map(\.label).joined(separator: "; "))
        }
    }

    mutating func check(
        _ caseID: String, _ passed: Bool, _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        check(caseID, [(passed, label)], sourceLocation: sourceLocation)
    }

    mutating func note(_ caseID: String, _ detail: String) {
        lines.append("\(caseID) note \(scenario): \(detail)")
    }

    mutating func skipped(_ caseID: String, _ detail: String) {
        lines.append("\(caseID) skipped \(scenario): \(detail)")
    }

    mutating func time(_ label: String, seconds: TimeInterval?) {
        let value = seconds.map { String(format: "%.1fs", $0) } ?? "unavailable"
        lines.append("time \(scenario) \(label) \(value)")
    }

    /// A timing the app logged itself, such as a CLI runtime's ready line, recorded verbatim.
    mutating func timeDetail(_ detail: String) {
        lines.append("time \(scenario) \(detail)")
    }
}
