import Foundation
import JarvisCore
import JarvisMCPBridge

private let token = "BLUEBIRD-742"
private let systemPrompt = """
You are validating a coaching action transport. First call capture_screen. Read the comparison token
from its OCR result. Then call speak with exactly one short line that contains that token. Do not
guess the token and do not finish with plain text.
"""
private let tinyJPEG = """
/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAEf/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABBQJ//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPwF//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBPwF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQAGPwJ//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPyF//9oADAMBAAIAAwAAABD/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/EB//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/EB//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/EB//2Q==
"""

private func callID(_ invocation: ToolInvocation) -> String {
    switch invocation {
    case .captureScreen(let callID), .speak(let callID, _), .staySilent(let callID):
        return callID
    }
}

private func terminalText(_ decision: CoachingActionBroker.TerminalDecision) -> String {
    switch decision {
    case .speak(_, let lines):
        return lines.joined(separator: " ")
    case .staySilent:
        return "stay_silent"
    }
}

private func makeBase(
    cli: DetectedAgentCLI,
    workDirectory: URL,
    counter: RunCounter
) -> CLIBrainClient {
    CLIBrainClient(
        provider: cli.provider,
        executable: cli.executableURL,
        model: "",
        reasoningEffort: ReasoningEffort.low.rawValue,
        workDirectory: workDirectory,
        codexSupportedFeatures: cli.supportedFeatures,
        timeout: 120,
        run: { invocation, timings in
            counter.increment()
            let dump = ProcessInfo.processInfo.environment["JARVIS_COMPARE_DUMP_CLI"] == "1"
            let actualInvocation: AgentCLIRun
            if dump, cli.provider == .claudeCode {
                actualInvocation = AgentCLIRun(
                    executable: invocation.executable,
                    arguments: invocation.arguments + [
                        "--debug-file",
                        workDirectory.appendingPathComponent("claude-debug.log").path,
                    ],
                    stdin: invocation.stdin,
                    workingDirectory: invocation.workingDirectory,
                    timeout: invocation.timeout)
            } else {
                actualInvocation = invocation
            }
            let output = try await AgentCLIProcessRunner.run(actualInvocation, timings: timings)
            if dump {
                let record = "STDOUT\n\(output.stdout)\n\nSTDERR\n\(output.stderr)"
                _ = FileManager.default.createFile(
                    atPath: workDirectory
                        .appendingPathComponent("cli-output-\(counter.value).txt").path,
                    contents: Data(record.utf8),
                    attributes: [.posixPermissions: 0o600])
            }
            return output
        })
}

private func runJSON(
    cli: DetectedAgentCLI,
    workDirectory: URL
) async -> ComparisonResult {
    let counter = RunCounter()
    let client = makeBase(cli: cli, workDirectory: workDirectory, counter: counter)
    let snapshot = ScreenSnapshot(
        imageBase64: tinyJPEG.replacingOccurrences(of: "\n", with: ""),
        recognizedText: "COMPARISON_TOKEN=\(token)")
    let broker = CoachingActionBroker(
        identity: .init(configurationRevision: 1),
        capture: { snapshot })
    var messages: [ChatMessage] = [.system(systemPrompt), .user("Inspect the screen, then coach me.")]
    let started = DispatchTime.now().uptimeNanoseconds
    do {
        for _ in 0..<4 {
            let response = try await client.respond(
                messages: messages,
                tools: coachTools,
                toolChoice: .required)
            guard response.toolCalls.count == 1,
                  let invocation = response.toolCalls.first else {
                throw CoachingActionBroker.Failure.missingTerminal
            }
            let result = try await broker.submit(invocation)
            if case .capture(let shot) = result {
                messages.append(.assistantToolCalls(response.rawToolCalls))
                messages.append(.init(
                    role: .tool,
                    text: shot.map {
                        "screenshot captured\n\nOn-device OCR:\n\($0.recognizedText ?? "")"
                    } ?? "screenshot failed",
                    toolCallId: callID(invocation)))
                if let shot {
                    messages.append(.userImage(shot.imageBase64))
                }
                continue
            }
            let decision = try await broker.commit()
            let terminal = terminalText(decision)
            let elapsed = Int(
                (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            return ComparisonResult(
                provider: cli.provider.rawValue,
                transport: "json",
                processCount: counter.value,
                captureCount: await broker.events().filter {
                    if case .captured = $0 { return true }
                    return false
                }.count,
                validTerminal: true,
                evidenceUsed: terminal.contains(token),
                terminal: terminal,
                elapsedMs: elapsed,
                error: nil)
        }
        throw CoachingActionBroker.Failure.missingTerminal
    } catch {
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        return ComparisonResult(
            provider: cli.provider.rawValue,
            transport: "json",
            processCount: counter.value,
            captureCount: await broker.events().filter {
                if case .captured = $0 { return true }
                return false
            }.count,
            validTerminal: false,
            evidenceUsed: false,
            terminal: nil,
            elapsedMs: elapsed,
            error: error.localizedDescription)
    }
}

private func runMCP(
    cli: DetectedAgentCLI,
    workDirectory: URL,
    serverExecutable: URL
) async -> ComparisonResult {
    let counter = RunCounter()
    let base = makeBase(cli: cli, workDirectory: workDirectory, counter: counter)
    let snapshot = ScreenSnapshot(
        imageBase64: tinyJPEG.replacingOccurrences(of: "\n", with: ""),
        recognizedText: "COMPARISON_TOKEN=\(token)")
    let broker = CoachingActionBroker(
        identity: .init(configurationRevision: 1),
        capture: { snapshot })
    let started = DispatchTime.now().uptimeNanoseconds
    var finalText: String?
    do {
        let host = MCPBridgeHost(
            sessionDirectory: workDirectory,
            serverExecutable: serverExecutable,
            broker: broker)
        let configuration = try host.start()
        defer { host.close() }
        let response = try await base.respondUsingMCP(
            messages: [.system(systemPrompt), .user("Inspect the screen, then coach me.")],
            tools: coachTools,
            toolChoice: .required,
            configuration: configuration)
        finalText = response.outputText
        _ = try await broker.requireTerminal()
        let decision = try await broker.commit()
        let terminal = terminalText(decision)
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        return ComparisonResult(
            provider: cli.provider.rawValue,
            transport: "mcp",
            processCount: counter.value,
            captureCount: await broker.events().filter {
                if case .captured = $0 { return true }
                return false
            }.count,
            validTerminal: true,
            evidenceUsed: terminal.contains(token),
            terminal: terminal,
            elapsedMs: elapsed,
            error: nil)
    } catch {
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        return ComparisonResult(
            provider: cli.provider.rawValue,
            transport: "mcp",
            processCount: counter.value,
            captureCount: await broker.events().filter {
                if case .captured = $0 { return true }
                return false
            }.count,
            validTerminal: false,
            evidenceUsed: false,
            terminal: nil,
            elapsedMs: elapsed,
            error: [
                error.localizedDescription,
                finalText.map { "final output: \($0)" },
            ].compactMap { $0 }.joined(separator: "; "))
    }
}

private func argument(after flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag),
          CommandLine.arguments.indices.contains(index + 1) else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

let provider: BrainProvider
switch argument(after: "--provider") {
case "claude":
    provider = .claudeCode
case "codex":
    provider = .codexCLI
default:
    FileHandle.standardError.write(
        Data("usage: ActionTransportComparison --provider claude|codex --server PATH --session-dir PATH\n".utf8))
    exit(2)
}
guard let serverPath = argument(after: "--server"),
      let directoryPath = argument(after: "--session-dir") else {
    FileHandle.standardError.write(Data("missing --server or --session-dir\n".utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: directoryPath)
try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
guard let cli = AgentCLIDetector().detect(provider) else {
    FileHandle.standardError.write(Data("\(provider.displayName) CLI not found\n".utf8))
    exit(2)
}

let selectedTransport = argument(after: "--transport") ?? "both"
var results: [ComparisonResult] = []
if selectedTransport == "both" || selectedTransport == "json" {
    results.append(await runJSON(cli: cli, workDirectory: directory))
}
if selectedTransport == "both" || selectedTransport == "mcp" {
    results.append(await runMCP(
        cli: cli,
        workDirectory: directory,
        serverExecutable: URL(fileURLWithPath: serverPath)))
}
let data = try JSONEncoder().encode(results)
let object = try JSONSerialization.jsonObject(with: data)
let pretty = try JSONSerialization.data(
    withJSONObject: object,
    options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(pretty)
FileHandle.standardOutput.write(Data("\n".utf8))
let comparisonPassed = results.allSatisfy {
    $0.captureCount == 1
        && $0.validTerminal
        && $0.evidenceUsed
        && $0.processCount == ($0.transport == "mcp" ? 1 : 2)
}
if !comparisonPassed {
    exit(1)
}
