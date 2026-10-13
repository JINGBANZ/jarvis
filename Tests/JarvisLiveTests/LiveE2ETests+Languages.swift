import Foundation
import JarvisCore
import Testing

extension LiveE2ETests {
    @Test func scenarioL() async throws {
        for target in TranscriptionTarget.remoteTargets {
            let id = "L-\(target.provider.rawValue)-\(target.modelID!)".replacingOccurrences(of: ".", with: "-")
            guard let launcher = await LiveE2ELauncher.begin(
                scenario: id, file: "L", transcriptionTarget: target) else { continue }
            let launch = try await launcher.launch()
            var results = LiveE2EResults(scenario: id)
            if let evidence = Self.requireEvidence(launch, &results) {
                let transcript = evidence.attempts.flatMap(\.transcript)
                for speaker in [Speaker.me, .them] {
                    let activity = evidence.activity.filter {
                        $0.kind == "heard" && $0.message.hasPrefix("🗣 heard (\(speaker.rawValue))")
                    }.map(\.message).joined()
                    let coaching = transcript.filter { $0.speaker == speaker.rawValue }.map(\.text).joined()
                    for (boundary, texts) in [("Activity", activity), ("coaching", coaching)] {
                        results.check("L-\(speaker.rawValue)-\(boundary)", [
                            (texts.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                             "\(speaker.rawValue) retained Mandarin in \(boundary)"),
                            (texts.lowercased().contains(speaker == .me ? "commit" : "actor"),
                             "\(speaker.rawValue) retained the English technical term in \(boundary)"),
                            (TranscriptionBenchmark.unexpectedScriptCharacterCount(in: texts) == 0,
                             "\(speaker.rawValue) had no unexpected script in \(boundary)"),
                        ])
                    }
                }
                let marker = target.confirmation == .effectiveConfiguration
                    ? "effective transcription configuration verified"
                    : "transcription setup acknowledged; settings are not echoed"
                results.check("L-setup", [
                    (evidence.debugLines.filter { $0.contains(marker) }.count >= 2,
                     "both streams recorded their provider's setup confirmation"),
                    (!evidence.attempts.isEmpty, "the full session reached coaching"),
                ])
                Self.checkCleanEnd(launch, evidence, endedByUser: true, &results)
            }
            try launcher.finish(results)
        }
    }
}
