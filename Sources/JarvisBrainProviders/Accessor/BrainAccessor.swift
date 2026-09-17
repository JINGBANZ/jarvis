import Foundation
import JarvisCore
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession/URLRequest live here on non-Darwin (Core tests on Linux)
#endif

public struct BrainAccessor: BrainClient, Sendable {
    public typealias Sender = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse?)

    private let provider: BrainProvider
    private let apiKey: String
    private let model: String
    private let reasoningEffort: String
    private let endpoint: URL
    private let timeout: TimeInterval
    private let maxOutputTokens: Int
    private let promptCacheKey: String
    private let toolChoicePolicy: ToolChoicePolicy
    private let send: Sender?
    private let traffic: (any BrainTrafficAuditing)?
    private let trafficTag: String

    public init(provider: BrainProvider = .openAI,
                apiKey: String,
                model: String,
                reasoningEffort: String = Defaults.Brain.effort.rawValue,
                endpoint: URL = BrainProviderDescriptor.openAIResponsesEndpoint,
                timeout: TimeInterval = BrainWorkloadTimeout.liveCoaching,
                // Reasoning plus output budget: it must track the effort or the run truncates.
                maxOutputTokens: Int = Defaults.Brain.effort.maxOutputTokens,
                promptCacheKey: String = "jarvis-coach-v1",
                toolChoicePolicy: ToolChoicePolicy = .providerEnforced,
                minimumReasoningEffort: ReasoningEffort? = nil,
                traffic: (any BrainTrafficAuditing)? = nil,
                trafficTag: String = "coach",
                send: Sender? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model
        // Raise to the floor without rewriting the user's shared preference, which other models may
        // still use to disable reasoning.
        let floor = [minimumReasoningEffort,
                     BrainModelCatalog.model(id: model, for: provider)?.reasoningEffortFloor]
            .compactMap { $0 }.max()
        if let floor, let selected = ReasoningEffort(rawValue: reasoningEffort), selected < floor {
            self.reasoningEffort = floor.rawValue
            self.maxOutputTokens = max(maxOutputTokens, floor.maxOutputTokens)
        } else {
            self.reasoningEffort = reasoningEffort
            self.maxOutputTokens = maxOutputTokens
        }
        self.endpoint = endpoint
        self.timeout = timeout
        self.promptCacheKey = promptCacheKey
        self.toolChoicePolicy = toolChoicePolicy
        self.traffic = traffic
        self.trafficTag = trafficTag
        self.send = send
    }

    public func respond(messages: [ChatMessage], tools: [ToolDef],
                        toolChoice: ToolChoice) async throws -> BrainResponse {
        do {
            return try await performRequest(
                messages: messages, tools: tools, toolChoice: toolChoice)
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            // One round trip with nothing ready behind it: a refused connection is unreachable.
            throw ProviderFailure(unclassified: error, source: .brain(provider), stage: .request)
        }
    }

    private func performRequest(messages: [ChatMessage], tools: [ToolDef],
                                toolChoice: ToolChoice) async throws -> BrainResponse {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body = try encodeBody(messages: messages, tools: tools, toolChoice: toolChoice)
        request.httpBody = body

        // Exactly one request, never retried: a fresh attempt should include newer transcript.
        let started = Date()
        let diagnostics = OpenAINetworkDiagnostics()
        let data: Data
        let http: HTTPURLResponse?
        do {
            if let send {
                (data, http) = try await send(request)
            } else {
                let result = try await URLSession.shared.data(for: request, delegate: diagnostics)
                (data, http) = (result.0, result.1 as? HTTPURLResponse)
            }
        } catch {
            traffic?.record(tag: trafficTag, provider: provider, request: body, response: nil, status: nil,
                            latencyMs: Self.elapsedMs(since: started),
                            error: OpenAINetworkDiagnostics.errorSummary(error), phases: diagnostics.phases)
            throw error
        }
        let status = http?.statusCode ?? 0
        traffic?.record(tag: trafficTag, provider: provider, request: body, response: data, status: status,
                        latencyMs: Self.elapsedMs(since: started), phases: diagnostics.phases)
        guard (200..<300).contains(status) else {
            throw OpenAIFailureClassifier.classify(
                httpStatus: status, body: data, source: .brain(provider), stage: .request)
        }
        return try decode(data)
    }

    private static func elapsedMs(since started: Date) -> Int {
        Int(Date().timeIntervalSince(started) * 1000)
    }

    // MARK: - Encoding (Responses API)

    private func encodeBody(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) throws -> Data {
        var instructions: [String] = []
        var input: [[String: Any]] = []

        for m in messages {
            switch m.role {
            case .system:
                if let t = m.text { instructions.append(t) }

            case .user:
                if let img = m.imageBase64JPEG {
                    input.append([
                        "role": "user",
                        "content": [["type": "input_image",
                                     "image_url": "data:image/jpeg;base64,\(img)"]],
                    ])
                } else {
                    input.append([
                        "role": "user",
                        "content": [["type": "input_text", "text": m.text ?? ""]],
                    ])
                }

            case .assistant:
                // OpenAI requires a function call's output items, reasoning included, to be
                // replayed unmodified and in order, or linkage validation fails.
                if let raw = m.rawItemsJSON {
                    for itemJSON in raw {
                        if let item = (try? JSONSerialization.jsonObject(with: Data(itemJSON.utf8))) as? [String: Any] {
                            input.append(item)
                        }
                    }
                }
                if let calls = m.toolCalls {
                    for c in calls {
                        input.append([
                            "type": "function_call",
                            "call_id": c.id,
                            "name": c.name,
                            "arguments": c.argumentsJSON,
                        ])
                    }
                } else if let t = m.text {
                    input.append(["role": "assistant",
                                  "content": [["type": "output_text", "text": t]]])
                }

            case .tool:
                input.append([
                    "type": "function_call_output",
                    "call_id": m.toolCallId ?? "",
                    "output": m.text ?? "",
                ])
            }
        }

        // A `filteredAuto` provider can't force or narrow a call, so the declared tools carry the
        // permitted set. That costs the prompt cache from the tools block on, about a second.
        let declared: [ToolDef]
        switch (toolChoicePolicy, toolChoice) {
        case (.filteredAuto, .allowed(let names)): declared = tools.filter { names.contains($0.name) }
        case (.filteredAuto, .force(let name)): declared = tools.filter { $0.name == name }
        default: declared = tools
        }
        let toolsJSON: [[String: Any]] = try declared.map { t in
            let params = try JSONSerialization.jsonObject(with: Data(t.parametersJSON.utf8))
            // Responses uses a flat function tool shape. `strict` requires every object in the
            // schema to set additionalProperties:false and list all keys as required.
            return ["type": "function", "name": t.name, "description": t.description,
                    "parameters": params, "strict": true]
        }

        // A subset narrows tool_choice, not the declared tools, so the cached prefix holds.
        let toolChoiceJSON: Any
        switch toolChoicePolicy == .filteredAuto ? ToolChoice.auto : toolChoice {
        case .auto: toolChoiceJSON = "auto"
        case .required: toolChoiceJSON = "required"
        case .allowed(let names):
            toolChoiceJSON = [
                "type": "allowed_tools",
                "mode": "required",
                "tools": names.map { ["type": "function", "name": $0] },
            ] as [String: Any]
        case .force(let name): toolChoiceJSON = ["type": "function", "name": name]
        }

        var body: [String: Any] = [
            "model": model,
            "input": input,
            "tools": toolsJSON,
            "tool_choice": toolChoiceJSON,
            "parallel_tool_calls": false,      // the coach loop consumes one tool call per turn
            "reasoning": ["effort": reasoningEffort],
            "max_output_tokens": maxOutputTokens,
            // store:true deliberately retains transcripts and screenshots at OpenAI for dashboard
            // debugging (wiki/sandbox.md). Subscription targets send false so a helper bump can't
            // turn retention back on.
            "store": !provider.servedByLocalProxy,
            "prompt_cache_key": promptCacheKey, // stable system prompt → better cache routing
        ]
        if !instructions.isEmpty {
            body["instructions"] = instructions.joined(separator: "\n\n")
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Decoding (Responses API)

    private struct Response: Decodable {
        struct Item: Decodable {
            struct ContentPart: Decodable {
                let type: String
                let text: String?
            }
            let type: String
            let call_id: String?
            let name: String?
            let arguments: String?
            let content: [ContentPart]?
        }
        struct IncompleteDetails: Decodable { let reason: String? }
        struct Usage: Decodable {
            struct InputDetails: Decodable { let cached_tokens: Int? }
            struct OutputDetails: Decodable { let reasoning_tokens: Int? }
            let input_tokens: Int?
            let input_tokens_details: InputDetails?
            let output_tokens: Int?
            let output_tokens_details: OutputDetails?
        }
        let output: [Item]
        let status: String?
        let incomplete_details: IncompleteDetails?
        let usage: Usage?
    }

    private func decode(_ data: Data) throws -> BrainResponse {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        // Logged to tune the per-effort budgets from real use. History is append-only to keep
        // `cached` high, so a run of zeros needs investigating.
        if let usage = decoded.usage {
            let input = usage.input_tokens ?? 0
            let cached = usage.input_tokens_details?.cached_tokens ?? 0
            let reasoning = usage.output_tokens_details?.reasoning_tokens ?? 0
            let truncated = decoded.status == "incomplete" ? " [incomplete]" : ""
            jlog("Jarvis coach: tokens — input \(input) (\(cached) cached), reasoning \(reasoning), output \(usage.output_tokens ?? 0), cap \(maxOutputTokens)\(truncated)")
        }
        var invocations: [ToolInvocation] = []
        var raws: [RawToolCall] = []
        // Unused by coaching turns, but the whole payload of a tool-less summarizer call.
        let outputText = decoded.output
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined()
        for item in decoded.output where item.type == "function_call" {
            guard let callId = item.call_id, let name = item.name else { continue }
            let args = item.arguments ?? "{}"
            raws.append(RawToolCall(id: callId, name: name, argumentsJSON: args))
            if let invocation = ToolInvocation.parse(callId: callId, name: name, argumentsJSON: args) {
                invocations.append(invocation)
            } else {
                jlog("Jarvis coach: ignoring unknown tool '\(name)'")
            }
        }
        // A truncated run can carry zero tool calls; the reason keeps it from reading as a silence.
        let incompleteReason = decoded.status == "incomplete"
            ? (decoded.incomplete_details?.reason ?? "incomplete")
            : nil
        return BrainResponse(toolCalls: invocations, rawToolCalls: raws,
                             incompleteReason: incompleteReason,
                             outputText: outputText.isEmpty ? nil : outputText,
                             outputItemsJSON: Self.outputItemsJSON(in: data))
    }

    /// Read from the raw bytes because replay must keep fields `Response` doesn't model, such as
    /// reasoning ids and encrypted payloads.
    private static func outputItemsJSON(in data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else { return [] }
        return output.compactMap { item in
            guard let bytes = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
    }
}
