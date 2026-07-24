import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession/URLRequest live here on non-Darwin (Core tests on Linux)
#endif

/// Brain client over the OpenAI **Responses API** (`POST /v1/responses`) — the recommended
/// endpoint for tool use with gpt-5.5. System text is passed via `instructions`; the conversation
/// is sent as typed `input` items; function calls are threaded with `function_call` /
/// `function_call_output`. Every call is self-contained: session memory is client-managed
/// (`CoachHistory`) and arrives in `messages`, built in stable append-only order so OpenAI's prompt
/// cache keeps hitting. `store:true` keeps each request/response inspectable in the OpenAI dashboard
/// logs for debugging (a documented retention tradeoff; see wiki/sandbox.md).
public struct OpenAIBrainClient: BrainClient, @unchecked Sendable {
    /// Injected transport; returns the body and the HTTP response (for status + headers).
    public typealias Sender = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse?)

    private let apiKey: String
    private let model: String
    private let reasoningEffort: String
    private let endpoint: URL
    private let timeout: TimeInterval
    private let maxOutputTokens: Int
    private let promptCacheKey: String
    private let send: Sender
    /// When set, every round trip (request body, response body, status, latency — or the transport
    /// error) is recorded to the session's `brain-traffic.jsonl`, tagged with `trafficTag` so the
    /// coach and the summarizer are distinguishable. Nil (tests, the evaluator itself) records nothing.
    private let traffic: BrainTrafficLog?
    private let trafficTag: String

    /// A generous request ceiling that is a HANG backstop, not a latency knob. Normal coaching turns
    /// finish in a few seconds; this only fires on a genuinely stuck request, so it sits well above the
    /// slow-but-real reasoning tail — a tight value (the old 15s) abandons a still-generating turn
    /// that would have finished.
    public static let defaultTimeout: TimeInterval = 60

    public init(apiKey: String,
                model: String,
                reasoningEffort: String = ReasoningEffort.default.rawValue,
                endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
                timeout: TimeInterval = OpenAIBrainClient.defaultTimeout,
                // The cap MUST track the effort: it's a combined reasoning+output budget, so a value
                // too small for the effort truncates the run (the high-effort bug). Callers pass the
                // budget for the *selected* effort (`AppDelegate` → `effort.maxOutputTokens`); this
                // default mirrors the default effort so there's one source of truth, never a magic number.
                maxOutputTokens: Int = ReasoningEffort.default.maxOutputTokens,
                promptCacheKey: String = "jarvis-coach-v1",
                traffic: BrainTrafficLog? = nil,
                trafficTag: String = "coach",
                send: Sender? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.endpoint = endpoint
        self.timeout = timeout
        self.maxOutputTokens = maxOutputTokens
        self.promptCacheKey = promptCacheKey
        self.traffic = traffic
        self.trafficTag = trafficTag
        self.send = send ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as? HTTPURLResponse)
        }
    }

    public func respond(messages: [ChatMessage], tools: [ToolDef],
                        toolChoice: ToolChoice) async throws -> BrainResponse {
        do {
            return try await performRequest(
                messages: messages, tools: tools, toolChoice: toolChoice)
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            throw BrainFailure(error)
        }
    }

    /// Keep classification at the provider boundary: callers—including the retry wrapper and
    /// `CoachDriver`—receive the same typed recoverability decision.
    private func performRequest(messages: [ChatMessage], tools: [ToolDef],
                                toolChoice: ToolChoice) async throws -> BrainResponse {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body = try encodeBody(messages: messages, tools: tools, toolChoice: toolChoice)
        request.httpBody = body

        // This transport makes one attempt. The app wraps it in `RetryingBrainClient`, which may
        // repeat the same self-contained request once for a transient transport/server failure.
        // After that, the error reaches the driver and the NEXT trigger recovers: `sentCount` only
        // advances on success, so the next turn's delta includes the failed lines plus newer ones.
        // Each attempt records its own traffic entry (the retry re-enters this method), so a failed
        // round trip AND its retry are both visible to the session audit.
        let started = Date()
        let data: Data
        let http: HTTPURLResponse?
        do {
            (data, http) = try await send(request)
        } catch {
            // Record the failed round trip too — a transport error (timeout, dropped connection) is
            // exactly the kind of issue the session evaluation should see.
            traffic?.record(tag: trafficTag, request: body, response: nil, status: nil,
                            latencyMs: Self.elapsedMs(since: started),
                            error: error.localizedDescription)
            throw error
        }
        let status = http?.statusCode ?? 0
        traffic?.record(tag: trafficTag, request: body, response: data, status: status,
                        latencyMs: Self.elapsedMs(since: started))
        guard (200..<300).contains(status) else {
            let identity = Self.errorIdentity(from: data)
            throw BrainFailure.openAIHTTP(
                status: status,
                errorCode: identity.code,
                errorType: identity.type,
                detail: String(data: data, encoding: .utf8) ?? "http \(status)")
        }
        return try decode(data)
    }

    private static func errorIdentity(from data: Data) -> (code: String?, type: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else {
            return (nil, nil)
        }
        return (error["code"] as? String, error["type"] as? String)
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
                // Verbatim passthrough items (a prior response's whole `output` array) go back
                // exactly as the model emitted them — OpenAI requires a function call's output items
                // (reasoning included) to accompany its result, unmodified and in order, or the
                // request fails linkage validation / the model re-reasons from scratch.
                if let raw = m.rawItemsJSON {
                    for itemJSON in raw {
                        if let item = (try? JSONSerialization.jsonObject(with: Data(itemJSON.utf8))) as? [String: Any] {
                            input.append(item)
                        }
                    }
                }
                // Replay the model's function calls as `function_call` input items (the tool loop).
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

        let toolsJSON: [[String: Any]] = try tools.map { t in
            let params = try JSONSerialization.jsonObject(with: Data(t.parametersJSON.utf8))
            // Responses API uses a FLAT function tool shape (no nested "function"). `strict:true`
            // turns on Structured Outputs for the call's arguments — the model is constrained to the
            // schema, so e.g. `speak`'s `lines` always decodes as an array of strings (no splitting
            // client-side). Strict requires every object in `parameters` to set
            // additionalProperties:false and list all its keys as required (see ToolDefs).
            return ["type": "function", "name": t.name, "description": t.description,
                    "parameters": params, "strict": true]
        }

        // Responses tool_choice: the strings "auto"/"required", or a {type:function,name} object to
        // force one specific function.
        let toolChoiceJSON: Any
        switch toolChoice {
        case .auto: toolChoiceJSON = "auto"
        case .required: toolChoiceJSON = "required"
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
            // store:true keeps each request/response inspectable in the OpenAI dashboard logs for
            // debugging. This DOES retain transcripts/screenshots server-side — a deliberate
            // debuggability-over-retention choice; see wiki/sandbox.md.
            "store": true,
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
        // Log per-turn token usage so the per-effort `max_output_tokens` budgets can be tuned DOWN
        // from real consumption (OpenAI's own advice). `reasoning` is the share spent thinking — the
        // part that silently ate the whole cap at high effort. `cached` is the prompt-cache hit for
        // this call: history is built append-only precisely so this stays high, so a run of zeros
        // here is the signal to investigate (per the session-audit finding), not a per-call anomaly.
        if let usage = decoded.usage {
            let input = usage.input_tokens ?? 0
            let cached = usage.input_tokens_details?.cached_tokens ?? 0
            let reasoning = usage.output_tokens_details?.reasoning_tokens ?? 0
            let truncated = decoded.status == "incomplete" ? " [incomplete]" : ""
            jlog("Jarvis coach: tokens — input \(input) (\(cached) cached), reasoning \(reasoning), output \(usage.output_tokens ?? 0), cap \(maxOutputTokens)\(truncated)")
        }
        var invocations: [ToolInvocation] = []
        var raws: [RawToolCall] = []
        // Plain text output — unused by coaching turns (tool_choice: required) but the whole payload
        // of a tool-less summarizer call.
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
        // A truncated run (`status:"incomplete"`, e.g. reasoning+output exceeding max_output_tokens)
        // can carry zero tool calls — surface the reason so the coach loop doesn't mistake it for
        // a deliberate stay-silent. Prefer the explicit reason; fall back to "incomplete".
        let incompleteReason = decoded.status == "incomplete"
            ? (decoded.incomplete_details?.reason ?? "incomplete")
            : nil
        return BrainResponse(toolCalls: invocations, rawToolCalls: raws,
                             incompleteReason: incompleteReason,
                             outputText: outputText.isEmpty ? nil : outputText,
                             outputItemsJSON: Self.outputItemsJSON(in: data))
    }

    /// The response's entire `output` array, each item re-serialized whole so the tool loop can
    /// replay it untouched (`input.push(...response.output)` — reasoning ids, function_call item
    /// ids, any encrypted payload all preserved). Extracted from the raw bytes — the typed
    /// `Response` above deliberately doesn't model every provider field, and replay must lose none.
    private static func outputItemsJSON(in data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else { return [] }
        return output.compactMap { item in
            guard let bytes = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
    }
}
