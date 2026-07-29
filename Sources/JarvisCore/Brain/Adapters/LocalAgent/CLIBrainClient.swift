import Foundation

/// Subscription-backed brain client over a provider-native persistent local-agent runtime.
///
/// Claude uses a preinitialized, single-use query lease with one replacement kept ready. Codex uses
/// one session-scoped app-server and a fresh ephemeral thread per coaching attempt. Neither provider
/// has a one-shot coaching fallback: runtime failure is a failed provider attempt and is handled by
/// the ordered route.
public struct CLIBrainClient: BrainClient, Sendable {
    let provider: BrainProvider
    let traffic: BrainTrafficLog?
    let trafficTag: String
    let expectedInstructions: String
    let configuration: LocalAgentConversationConfiguration
    let runtime: CLIBrainRuntime
    private let runtimeLease: CLIBrainRuntime.Lease

    /// A local agent turn's remote inference still needs a generous hang backstop.
    public static let defaultTimeout: TimeInterval = 120
    /// A silent Codex runtime stall must not batch later transcript turns for two minutes.
    public static let codexDefaultTimeout: TimeInterval = 30

    public init(
        provider: BrainProvider,
        executable: URL,
        model: String,
        reasoningEffort: String = ReasoningEffort.default.rawValue,
        workDirectory: URL,
        timeout: TimeInterval? = nil,
        traffic: BrainTrafficLog? = nil,
        trafficTag: String = "coach",
        systemPrompt: String,
        tools: [ToolDef],
        toolChoice: ToolChoice,
        runtime: CLIBrainRuntime? = nil,
        prewarm: Bool = true
    ) {
        precondition(provider.usesLocalCLI, "CLIBrainClient needs a CLI provider, got \(provider)")
        let normalizedChoice = Self.instructionChoice(toolChoice)
        let instructions = Self.composeInstructions(
            system: [systemPrompt],
            tools: tools,
            toolChoice: normalizedChoice)
        let resolvedRuntime = runtime ?? CLIBrainRuntime(provider: provider)
        let configuration = LocalAgentConversationConfiguration(
            provider: provider,
            executable: executable,
            model: model,
            reasoningEffort: reasoningEffort,
            workDirectory: workDirectory,
            instructions: instructions,
            timeout: timeout ?? (provider == .codexCLI
                                 ? Self.codexDefaultTimeout : Self.defaultTimeout))
        self.provider = provider
        self.traffic = traffic
        self.trafficTag = trafficTag
        self.expectedInstructions = instructions
        self.configuration = configuration
        self.runtime = resolvedRuntime
        self.runtimeLease = resolvedRuntime.acquireLease()
        if prewarm {
            prepare()
        }
    }

    public func makeConversation() async throws -> any BrainConversation {
        let openEntered = DispatchTime.now().uptimeNanoseconds
        do {
            let transport = try await runtime.openConversation(for: configuration)
            return CLIBrainConversation(client: self, transport: transport)
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            recordFailure(error, requestRecord: nil, respondEntered: openEntered)
            throw BrainFailure(error)
        }
    }

    public func terminate() {
        runtimeLease.release()
    }

    public func prepare() {
        runtime.prepareInBackground(for: configuration)
    }

    /// Auxiliary callers such as memory compaction still use the simple `respond` surface. It opens
    /// and closes a provider-native conversation; it never falls back to a per-turn command.
    public func respond(messages: [ChatMessage], tools: [ToolDef],
                        toolChoice: ToolChoice) async throws -> BrainResponse {
        let conversation = try await makeConversation()
        do {
            let response = try await conversation.respond(
                messages: messages, tools: tools, toolChoice: toolChoice)
            await conversation.finish()
            return response
        } catch {
            await conversation.finish()
            throw error
        }
    }

    func prepareTurn(
        messages: [ChatMessage],
        previousMessageIdentities: [MessageIdentity],
        tools: [ToolDef],
        toolChoice: ToolChoice
    ) throws -> (turn: LocalAgentTurn, requestRecord: Data, identities: [MessageIdentity]) {
        let identities = messages.map(MessageIdentity.init)
        let isFirst = previousMessageIdentities.isEmpty
        if !isFirst {
            guard identities.count >= previousMessageIdentities.count,
                  Array(identities.prefix(previousMessageIdentities.count))
                    == previousMessageIdentities else {
                throw Self.error("a local-agent conversation was rewritten inside one attempt")
            }
        }

        let renderedAll = renderConversation(messages)
        let actualInstructions = Self.composeInstructions(
            system: renderedAll.system,
            tools: tools,
            toolChoice: Self.instructionChoice(toolChoice))
        guard actualInstructions == expectedInstructions else {
            throw Self.error("local-agent instructions changed after runtime initialization")
        }

        let inputMessages = isFirst
            ? messages
            : Array(messages.dropFirst(previousMessageIdentities.count)).filter {
                $0.role != .system && $0.role != .assistant
            }
        let rendered = renderConversation(inputMessages)
        var input: [LocalAgentInput] = []
        var auditInput: [[String: Any]] = []
        var textRun = [isFirst ? "## Conversation" : "## New input"]

        func flushText() {
            guard !textRun.isEmpty else { return }
            let text = textRun.joined(separator: "\n\n")
            input.append(.text(text))
            auditInput.append(["type": "text", "text": text])
            textRun = []
        }

        for segment in rendered.segments {
            switch segment {
            case .text(let text):
                textRun.append(text)
            case .imageJPEG(let base64):
                textRun.append("[user]\n(screenshot below)")
                flushText()
                input.append(.imageJPEG(base64: base64))
                auditInput.append([
                    "type": "image",
                    "image": Self.imageStub(base64),
                ])
            }
        }
        if !tools.isEmpty {
            var trailer = "Answer now, following the tool protocol."
            if let forced = Self.forcedToolDirective(toolChoice) {
                trailer += " \(forced)"
            }
            textRun.append(trailer)
        }
        flushText()

        let record: [String: Any] = [
            "provider": provider.rawValue,
            "model": configuration.model.isEmpty ? "(CLI default)" : configuration.model,
            "executable": configuration.executable.path,
            "runtime": provider == .claudeCode ? "warm-query" : "app-server",
            "instructions": expectedInstructions,
            "input": auditInput,
        ]
        return (
            LocalAgentTurn(input: input, timeout: configuration.timeout),
            Self.recordData(record),
            identities)
    }

    func finishResponse(
        _ result: LocalAgentTurnResult,
        tools: [ToolDef],
        toolChoice: ToolChoice,
        requestRecord: Data,
        respondEntered: UInt64
    ) -> BrainResponse {
        let response = parse(reply: result.reply, tools: tools, toolChoice: toolChoice)
        let parsedAt = DispatchTime.now().uptimeNanoseconds
        let phases = Self.phaseDurationsMs(
            result: result,
            respondEntered: respondEntered,
            parsedAt: parsedAt)
        logPhases(phases, note: "ok")
        traffic?.record(
            tag: trafficTag,
            request: requestRecord,
            response: responseRecord(result),
            status: 200,
            latencyMs: Self.totalLatencyMs(in: phases),
            phases: phases)
        return response
    }

    func recordFailure(_ error: Error, requestRecord: Data?, respondEntered: UInt64) {
        let totalMs = Int(
            (DispatchTime.now().uptimeNanoseconds - respondEntered) / 1_000_000)
        let phases = ["totalMs": totalMs]
        logPhases(phases, note: "failed")
        traffic?.record(
            tag: trafficTag,
            request: requestRecord ?? Self.recordData([
                "provider": provider.rawValue,
                "runtime": provider == .claudeCode ? "warm-query" : "app-server",
            ]),
            response: nil,
            status: nil,
            latencyMs: totalMs,
            error: error.localizedDescription,
            phases: phases)
    }

    private func responseRecord(_ result: LocalAgentTurnResult) -> Data {
        var record: [String: Any] = ["reply": result.reply]
        if let metadata = result.metadata,
           let object = try? JSONSerialization.jsonObject(with: metadata) {
            // Keep Claude's established `response.cli` envelope so deterministic session metrics
            // retain usage/cache/cost telemetry. Codex's completed-turn metadata has no usage.
            record[provider == .claudeCode ? "cli" : "runtime"] = object
        }
        return Self.recordData(record)
    }

    static func recordData(_ record: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: record)) ?? Data()
    }

    static func phaseDurationsMs(
        result: LocalAgentTurnResult,
        respondEntered: UInt64,
        parsedAt: UInt64
    ) -> [String: Int] {
        func milliseconds(_ from: UInt64?, _ to: UInt64?) -> Int? {
            guard let from, let to, to >= from else { return nil }
            return Int((to - from) / 1_000_000)
        }
        var phases: [String: Int] = [:]
        phases["queuedMs"] = milliseconds(respondEntered, result.dispatchedAt)
        phases["firstOutputMs"] = milliseconds(
            result.dispatchedAt, result.firstAssistantAt)
        phases["outputMs"] = milliseconds(result.firstAssistantAt, result.completedAt)
        phases["parseMs"] = milliseconds(result.completedAt, parsedAt)
        phases["totalMs"] = milliseconds(respondEntered, parsedAt)
        return phases
    }

    static func totalLatencyMs(in phases: [String: Int]) -> Int {
        guard let total = phases["totalMs"] else {
            preconditionFailure("a completed phase snapshot always has a total")
        }
        return total
    }

    func logPhases(_ phases: [String: Int], note: String) {
        let order = ["queuedMs", "firstOutputMs", "outputMs", "parseMs", "totalMs"]
        let parts = order.compactMap { key in
            phases[key].map { "\(key.dropLast(2))=\($0)ms" }
        }
        jlog("Jarvis \(trafficTag): \(provider.rawValue) runtime phases (\(note)) — "
             + parts.joined(separator: " "))
    }

    static func instructionChoice(_ choice: ToolChoice) -> ToolChoice {
        if case .force = choice { return .required }
        return choice
    }

    struct MessageIdentity: Sendable, Equatable {
        let role: ChatMessage.Role
        let text: String?
        let imageBase64JPEG: String?
        let toolCallId: String?
        let toolCalls: [RawToolCall]?
        let rawItemsJSON: [String]?

        init(_ message: ChatMessage) {
            role = message.role
            text = message.text
            imageBase64JPEG = message.imageBase64JPEG
            toolCallId = message.toolCallId
            toolCalls = message.toolCalls
            rawItemsJSON = message.rawItemsJSON
        }
    }

    static func imageStub(_ base64: String) -> String {
        "[image/jpeg — \(base64.count) base64 chars, redacted]"
    }

    static func error(_ message: String, code: Int = 1) -> NSError {
        NSError(domain: "CLIBrainClient", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private actor CLIBrainConversation: BrainConversation {
    let client: CLIBrainClient
    let transport: any LocalAgentConversation
    var previousMessageIdentities: [CLIBrainClient.MessageIdentity] = []
    var isFinished = false

    init(client: CLIBrainClient, transport: any LocalAgentConversation) {
        self.client = client
        self.transport = transport
    }

    func respond(messages: [ChatMessage], tools: [ToolDef],
                 toolChoice: ToolChoice) async throws -> BrainResponse {
        guard !isFinished else {
            throw CLIBrainClient.error("local-agent conversation was already finished")
        }
        let respondEntered = DispatchTime.now().uptimeNanoseconds
        var requestRecord: Data?
        do {
            let prepared = try client.prepareTurn(
                messages: messages,
                previousMessageIdentities: previousMessageIdentities,
                tools: tools,
                toolChoice: toolChoice)
            requestRecord = prepared.requestRecord
            previousMessageIdentities = prepared.identities
            let result = try await transport.respond(to: prepared.turn)
            return client.finishResponse(
                result,
                tools: tools,
                toolChoice: toolChoice,
                requestRecord: prepared.requestRecord,
                respondEntered: respondEntered)
        } catch {
            client.recordFailure(
                error,
                requestRecord: requestRecord,
                respondEntered: respondEntered)
            if Task.isCancelled || error is CancellationError { throw error }
            throw BrainFailure(error)
        }
    }

    func finish() async {
        guard !isFinished else { return }
        isFinished = true
        await transport.finish()
    }
}
