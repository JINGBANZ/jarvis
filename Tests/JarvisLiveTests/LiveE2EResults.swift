import Foundation
import Testing

/// A `note` never fails the run; never turn an assertion into a note to make a run pass.
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

    /// Totals cover the calls that reported usage; the rest are counted, never read as zero, so a
    /// failed request cannot pass for a cheap one.
    mutating func tokens(
        _ label: String, calls: Int, withoutUsage: Int, input: Int, cacheRead: Int, cacheWrite: Int,
        output: Int
    ) {
        let missing = withoutUsage > 0 ? " (\(withoutUsage) without usage)" : ""
        lines.append("tokens \(scenario) \(label) \(calls) calls\(missing), input \(input), "
            + "cache read \(cacheRead), cache write \(cacheWrite), output \(output)")
    }
}
