import Foundation
import JarvisCore

enum InstallationVerification {
    private static let argument = "--verify-installation"
    private static let marker = "JARVIS_INSTALLATION_CHECK "
    private static let expectedSkills = [
        "behavioral", "coding", "coding-with-ai", "customer-scenario-design", "system-design",
    ]

    static func runIfRequested() {
        guard CommandLine.arguments.contains(argument) else { return }
        // The launcher cannot interrupt a stalled native model load inside this process.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
            FileHandle.standardError.write(Data("Installation verification timed out.\n".utf8))
            exit(70)
        }
        var receipt = Receipt()
        guard Array(CommandLine.arguments.dropFirst()) == [argument] else {
            finish(&receipt, error: "arguments")
        }
        guard let detector = SileroVoiceActivityDetector() else {
            finish(&receipt, error: "speech-model")
        }
        receipt.checks.append("speech-model")
        guard detector.verifyInference() else {
            finish(&receipt, error: "speech-inference")
        }
        receipt.checks.append("speech-inference")
        guard let aec = WebRTCEchoCanceller(),
              let resampler = Resampler(fromHz: 48_000, toHz: 16_000) else {
            finish(&receipt, error: "audio-processing")
        }
        let silence = [Int16](repeating: 0, count: 4_800)
        aec.processReverse(silence)
        guard aec.process(silence).count == silence.count,
              !resampler.convert(silence).isEmpty else {
            finish(&receipt, error: "audio-processing")
        }
        receipt.checks.append("audio-processing")
        receipt.skills = SkillCatalog.bundled().map(\.name)
        guard receipt.skills == expectedSkills else {
            finish(&receipt, error: "skills")
        }
        receipt.checks.append("skills")
        finish(&receipt)
    }

    private static func finish(_ receipt: inout Receipt, error: String? = nil) -> Never {
        receipt.error = error
        receipt.status = error == nil ? "passed" : "failed"
        do {
            let data = try JSONEncoder().encode(receipt)
            FileHandle.standardOutput.write(Data(marker.utf8) + data + Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Couldn't encode installation verification.\n".utf8))
            exit(70)
        }
        exit(error == nil ? 0 : 1)
    }

    private struct Receipt: Encodable {
        let schema = 1
        var status = "failed"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #endif
        var skills: [String] = []
        var checks: [String] = []
        var error: String?
    }
}
