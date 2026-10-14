#if JARVIS_LIVE_E2E
import Foundation

public enum LiveE2ECacheCheck {
    public static let scenarioID = "CACHE"
    public static let modelID = "gpt-6-luna"
    public static let warmupAttempts = 2
    public static let measuredAttempts = 6

    public struct Sample: Sendable {
        public let attemptID: Int
        public let totalInput: Int?
        public let cacheRead: Int?
        public let instructionsFingerprint: String
        public let toolsFingerprint: String
        public let settingsFingerprint: String
        public let contextRevision: UInt?
        public let inputFingerprints: [String]

        public init(
            attemptID: Int, totalInput: Int?, cacheRead: Int?,
            instructionsFingerprint: String, toolsFingerprint: String,
            settingsFingerprint: String, contextRevision: UInt?,
            inputFingerprints: [String]
        ) {
            self.attemptID = attemptID
            self.totalInput = totalInput
            self.cacheRead = cacheRead
            self.instructionsFingerprint = instructionsFingerprint
            self.toolsFingerprint = toolsFingerprint
            self.settingsFingerprint = settingsFingerprint
            self.contextRevision = contextRevision
            self.inputFingerprints = inputFingerprints
        }
    }

    public struct Result: Sendable {
        public let failures: [String]
        public let historyHits: Int
        public let weightedReadRate: Double?
        public var passed: Bool { failures.isEmpty }
    }

    public static func prefixTokenAllowance(for provider: BrainProvider) -> Int {
        // The pinned Codex route uses 1024-token checkpoints and rounds cached reads to 128.
        // Controlled replay evidence: wiki/live-e2e-tests.md#cache-regression-window
        provider == .codexSubscription ? 1_024 + 127 : 256
    }

    public static func evaluate(_ samples: [Sample], provider: BrainProvider = .openAI) -> Result {
        let allowance = prefixTokenAllowance(for: provider)
        guard samples.count == warmupAttempts + measuredAttempts else {
            return Result(
                failures: ["expected two warm-up and six measured initial requests, saw \(samples.count)"],
                historyHits: 0, weightedReadRate: nil)
        }
        var failures: [String] = []
        if Set(samples.map(\.attemptID)).count != samples.count {
            failures.append("initial requests belong to distinct completed attempts")
        }
        guard let staticInput = samples[0].totalInput, (1...272_000).contains(staticInput) else {
            return Result(failures: failures + ["the static-prefix baseline has no input usage"],
                          historyHits: 0, weightedReadRate: nil)
        }
        var reads = 0
        var inputs = 0
        var historyHits = 0
        var beyondStaticHits = 0
        var hasMissingUsage = false
        for index in warmupAttempts..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            if current.instructionsFingerprint != previous.instructionsFingerprint
                || current.toolsFingerprint != previous.toolsFingerprint
                || current.settingsFingerprint != previous.settingsFingerprint {
                failures.append("attempt \(current.attemptID) changed instructions, tools or settings in the steady window")
            }
            if current.contextRevision == nil || current.contextRevision != previous.contextRevision {
                failures.append("attempt \(current.attemptID) has no stable context revision in the steady window")
            }
            if previous.inputFingerprints.isEmpty
                || !current.inputFingerprints.starts(with: previous.inputFingerprints) {
                failures.append("attempt \(current.attemptID) rewrote the preceding initial request's input prefix")
            }
            guard let total = current.totalInput, (1...272_000).contains(total),
                  let read = current.cacheRead, read >= 0, read <= total,
                  let previousInput = previous.totalInput, (1...272_000).contains(previousInput) else {
                failures.append("attempt \(current.attemptID) has missing or invalid input/cache-read usage")
                hasMissingUsage = true
                continue
            }
            inputs += total
            reads += read
            if read >= previousInput - allowance { historyHits += 1 }
            if read >= staticInput + 1_024 { beyondStaticHits += 1 }
        }
        let rate = !hasMissingUsage && inputs > 0 ? Double(reads) / Double(inputs) : nil
        if historyHits < 5 {
            failures.append("\(historyHits)/6 initial requests reused the preceding input within \(allowance) tokens; need five")
        }
        if beyondStaticHits < 5 {
            failures.append("\(beyondStaticHits)/6 cache reads extended at least 1024 tokens beyond the cold static baseline; need five")
        }
        if rate.map({ $0 >= 0.8 }) != true {
            failures.append("token-weighted initial-request cache-read rate must be at least 80 percent")
        }
        return Result(failures: failures, historyHits: historyHits, weightedReadRate: rate)
    }
}
#endif
