import Foundation
import Testing
@testable import JarvisCore

/// Opt-in signed-in smoke test for the real provider runtimes.
///
/// The normal gate leaves this test inert. Run it with
/// `JARVIS_LIVE_AGENT_PROVIDER=claude-code` or `all` to make a billed/subscription-backed model
/// request. Codex remains in `all` only to verify its installed CLI is marked unavailable before
/// launch until app-server exposes a stable tool-free request mode.
@Suite(.serialized) struct CLIBrainRuntimeLiveTests {
    private static let prompt = """
    You are a deterministic transport test. Follow these two rules exactly:
    - When the newest user text contains STEP_ONE, call capture_screen.
    - After a capture_screen tool result says STEP_TWO, call stay_silent.
    Do not call speak.
    """

    @Test func signedInProviderKeepsOneAttemptAliveAcrossTwoTurns() async throws {
        let requested = ProcessInfo.processInfo.environment["JARVIS_LIVE_AGENT_PROVIDER"]
        guard let requested else { return }
        let providers: [BrainProvider]
        switch requested {
        case "all":
            providers = [.claudeCode, .codexCLI]
        case BrainProvider.claudeCode.rawValue:
            providers = [.claudeCode]
        case BrainProvider.codexCLI.rawValue:
            providers = [.codexCLI]
        default:
            Issue.record("unknown JARVIS_LIVE_AGENT_PROVIDER value: \(requested)")
            return
        }

        for provider in providers {
            try await verify(provider)
        }
    }

    private func verify(_ provider: BrainProvider) async throws {
        let detected = try #require(AgentCLIDetector().detect(provider))
        #expect(detected.authenticationStatus != .signedOut)
        if provider == .codexCLI {
            #expect(detected.coachingIsolation == .toolFreeModeUnavailable)
            return
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".jarvis", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let workDirectory = root.appendingPathComponent(
            "issue-110-live-\(provider.rawValue)-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let traffic = BrainTrafficLog()
        traffic.enable(directory: workDirectory)

        let runtime = CLIBrainRuntime(
            provider: provider,
            codexSupportedFeatures: detected.supportedFeatures)
        let client = CLIBrainClient(
            provider: provider,
            executable: detected.executableURL,
            model: BrainModelCatalog.defaultModel(for: provider).id,
            reasoningEffort: "low",
            workDirectory: workDirectory,
            traffic: traffic,
            trafficTag: "live-poc",
            systemPrompt: Self.prompt,
            tools: coachTools,
            toolChoice: .required,
            runtime: runtime,
            prewarm: true)

        let attemptStarted = ContinuousClock.now
        let conversation = try await client.makeConversation()
        let firstStarted = ContinuousClock.now
        let first = try await conversation.respond(
            messages: [.system(Self.prompt), .user("STEP_ONE")],
            tools: coachTools,
            toolChoice: .required)
        let firstElapsed = firstStarted.duration(to: .now)
        let call = try #require(first.rawToolCalls.first)
        guard case .captureScreen = try #require(first.toolCalls.first) else {
            Issue.record("\(provider.rawValue) did not request capture_screen")
            await conversation.finish()
            return
        }

        let secondStarted = ContinuousClock.now
        let second = try await conversation.respond(
            messages: [
                .system(Self.prompt),
                .user("STEP_ONE"),
                .assistantToolCalls([call]),
                .init(
                    role: .tool,
                    text: "STEP_TWO: capture completed; the screen is blank.",
                    toolCallId: call.id),
            ],
            tools: coachTools,
            toolChoice: .required)
        let secondElapsed = secondStarted.duration(to: .now)
        await conversation.finish()
        guard case .staySilent = try #require(second.toolCalls.first) else {
            Issue.record("\(provider.rawValue) did not continue with stay_silent")
            return
        }

        let total = attemptStarted.duration(to: .now)
        print(
            "ISSUE110_LIVE provider=\(provider.rawValue) "
            + "first_ms=\(milliseconds(firstElapsed)) "
            + "second_ms=\(milliseconds(secondElapsed)) "
            + "total_ms=\(milliseconds(total)) "
            + "traffic=\(workDirectory.appendingPathComponent(BrainTrafficLog.filename).path)")
    }

    private func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000)
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
