import XCTest

enum UIIssueEvidence {
    static func record(_ issue: XCTIssue, firstFilename: String, failureFilename: String) {
        guard let path = ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"] else { return }
        let location = issue.sourceCodeContext.location
        let sources = ["ReleaseReadinessTests.swift": "permissions", "ReleaseReadinessTests+Journey.swift": "journey"]
        let source = location.flatMap { sources[$0.fileURL.lastPathComponent] }
        let ownSource = source != nil
        var classification = (0...5).contains(issue.type.rawValue) ? "failure" : "unknown"
        var severity = 0
        let reference = issue as XCTIssueReference
        // Probe the public getters at runtime so older hosted XCTest SDKs can compile this source.
        if reference.responds(to: NSSelectorFromString("isFailure")), let value = reference.value(forKey: "isFailure") as? NSNumber {
            classification = value.boolValue ? "failure" : "non-failure"
        }
        if reference.responds(to: NSSelectorFromString("severity")), let value = reference.value(forKey: "severity") as? NSNumber,
           [4, 8].contains(value.intValue) { severity = value.intValue }
        let domains = [XCTestErrorDomain: "xctest", NSCocoaErrorDomain: "cocoa", NSPOSIXErrorDomain: "posix",
                       NSOSStatusErrorDomain: "osstatus", NSMachErrorDomain: "mach"]
        var errors: [[String: Any]] = []
        var current = issue.associatedError as NSError?
        for _ in 0..<3 {
            guard let error = current else { break }
            let category = domains[error.domain] ?? "other"
            let code = category != "other" && (-2_147_483_648...2_147_483_647).contains(error.code) ? error.code : 0
            errors.append(["category": category, "code": code])
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let value: [String: Any] = ["issueType": issue.type.rawValue, "sourceIsHarness": ownSource,
                                    "source": source ?? "external",
                                    "line": ownSource ? location?.lineNumber ?? 0 : 0,
                                    "classification": classification, "severity": severity, "errors": errors,
                                    "automationSignals": automationSignals(issue.compactDescription)]
        do {
            let data = try JSONSerialization.data(withJSONObject: value)
            let filenames = classification == "failure" ? [firstFilename, failureFilename] : [firstFilename]
            for filename in filenames {
                do {
                    try data.write(to: URL(fileURLWithPath: path).appendingPathComponent(filename), options: .withoutOverwriting)
                } catch CocoaError.fileWriteFileExists {
                }
            }
        } catch { print("Could not record the scalar UI issue metadata") }
    }

    private static func automationSignals(_ message: String) -> [String] {
        let patterns: [(String, [String])] = [
            ("snapshot", ["snapshot"]),
            ("connection", ["communication", "connection"]),
            ("not-running", ["not running"]),
            ("not-hittable", ["not hittable", "no hittable", "no hit point"]),
            ("element-match", ["no matches found", "multiple matching", "matching element"]),
            ("activation", ["failed to activate", "failed to launch"]),
            ("timeout", ["timed out", "timeout", "time allowance"]),
            ("event", ["synthesize", "event"]),
            ("permission", ["not authorized", "denied", "accessibility"]),
            ("interruption", ["interrupted", "unresponsive", "not responding"]),
        ]
        return patterns.compactMap { category, terms in
            terms.contains { message.localizedCaseInsensitiveContains($0) } ? category : nil
        }
    }
}
