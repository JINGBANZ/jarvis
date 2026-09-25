import Foundation
import JarvisCore
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession/URLRequest live here on non-Darwin (Core tests on Linux)
#endif

/// The one HTTP transport every brain target uses; the provider's descriptor picks the auth header,
/// the wire format, and the failure table.
public struct BrainAccessor: BrainClient, Sendable {
    /// Shaped like the production transport: the body arrives in chunks behind its headers.
    public typealias Sender = @Sendable (URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse?)

    private let provider: BrainProvider
    private let apiKey: String
    private let endpoint: URL
    private let timeout: TimeInterval
    private let wire: any BrainWireFormat
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
                minimumReasoningEffort: ReasoningEffort? = nil,
                stream: Bool = false,
                traffic: (any BrainTrafficAuditing)? = nil,
                trafficTag: String = "coach",
                send: Sender? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        // Raise to the floor without rewriting the user's shared preference, which other models may
        // still use to disable reasoning.
        let floor = [minimumReasoningEffort,
                     BrainModelCatalog.model(id: model, for: provider)?.reasoningEffortFloor]
            .compactMap { $0 }.max()
        var effort = reasoningEffort
        var cap = maxOutputTokens
        if let floor, let selected = ReasoningEffort(rawValue: reasoningEffort), selected < floor {
            effort = floor.rawValue
            cap = max(maxOutputTokens, floor.maxOutputTokens)
        }
        switch provider.descriptor.wire {
        case .responses:
            wire = ResponsesWireFormat(
                model: model, reasoningEffort: effort, maxOutputTokens: cap,
                store: !provider.servedByLocalProxy, stream: stream)
        case .messages:
            wire = MessagesWireFormat(
                model: model, reasoningEffort: effort, maxOutputTokens: cap, stream: stream)
        case .interactions:
            wire = InteractionsWireFormat(model: model, reasoningEffort: effort, maxOutputTokens: cap)
        }
        self.endpoint = endpoint
        self.timeout = timeout
        self.traffic = traffic
        self.trafficTag = trafficTag
        self.send = send
    }

    public func respond(messages: [ChatMessage], tools: [ToolDef],
                        toolChoice: ToolChoice) async throws -> BrainResponse {
        try await respond(messages: messages, tools: tools, toolChoice: toolChoice, progress: nil)
    }

    public func makeConversation(progress: ToolCallProgressSink?) async throws -> any BrainConversation {
        BrainAccessorConversation(accessor: self, progress: progress)
    }

    fileprivate func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice,
                             progress: ToolCallProgressSink?) async throws -> BrainResponse {
        do {
            return try await performRequest(
                messages: messages, tools: tools, toolChoice: toolChoice, progress: progress)
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            // One round trip with nothing ready behind it: a refused connection is unreachable.
            throw ProviderFailure(unclassified: error, source: .brain(provider), stage: .request)
        }
    }

    private func performRequest(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice,
                                progress: ToolCallProgressSink?) async throws -> BrainResponse {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in wire.requestHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        switch provider.descriptor.auth {
        case .bearer: request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .googAPIKey: request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        let body = try wire.encode(messages: messages, tools: tools, toolChoice: toolChoice)
        request.httpBody = body

        // Exactly one request, never retried: a fresh attempt should include newer transcript.
        let started = Date()
        let delegate = BrainRequestDelegate()
        let prepared = request
        let reply: Reply
        do {
            // `timeoutInterval` bounds only the wait between bytes, so a reply that keeps trickling
            // gets the same total deadline.
            reply = try await Self.withDeadline(timeout) {
                let (chunks, http) = try await self.open(prepared, delegate: delegate)
                return try await self.read(chunks, http: http, started: started,
                                           delegate: delegate, progress: progress)
            }
        } catch {
            traffic?.record(tag: trafficTag, provider: provider, request: body, response: nil, status: nil,
                            latencyMs: Self.elapsedMs(since: started),
                            error: BrainRequestDelegate.errorSummary(error), phases: delegate.phases)
            throw error
        }
        let data: Data
        switch reply.outcome {
        case .body(let received):
            data = received
            traffic?.record(tag: trafficTag, provider: provider, request: body, response: data,
                            status: reply.status, latencyMs: Self.elapsedMs(since: started),
                            phases: delegate.phases)
        case .failed(let failure):
            traffic?.record(tag: trafficTag, provider: provider, request: body,
                            response: failure.errorBody, status: reply.status,
                            latencyMs: Self.elapsedMs(since: started),
                            error: failure.errorBody == nil
                                ? "stream ended before its terminal event" : "stream ended with an error event",
                            phases: delegate.phases)
            throw self.failure(failure, status: reply.status)
        }
        guard (200..<300).contains(reply.status) else {
            throw failure(httpStatus: reply.status, body: data)
        }
        do {
            return try wire.decode(data)
        } catch let refusal as RefusedReply {
            throw ProviderFailure(
                source: .brain(provider), stage: .response, category: .rejected, disposition: .temporary,
                identity: .init(errorType: "refusal", errorCode: refusal.category),
                message: refusal.explanation)
        }
    }

    private struct Reply {
        enum Outcome {
            /// A whole body: an error status, an unstreamed reply, or the message a stream assembled.
            case body(Data)
            case failed(StreamFailure)
        }

        let status: Int
        let outcome: Outcome
    }

    private func open(_ request: URLRequest, delegate: BrainRequestDelegate) async throws
        -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse?) {
        if let send { return try await send(request) }
        let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: delegate)
        return (Self.lineChunks(of: bytes), response as? HTTPURLResponse)
    }

    /// Buffers everything but a 2xx event stream, which is decoded event by event. Reading stays
    /// inside the deadline's task, so `Task.checkCancellation` names a cancelled read for what it is
    /// instead of an early end of the stream.
    private func read(_ chunks: AsyncThrowingStream<Data, Error>, http: HTTPURLResponse?, started: Date,
                      delegate: BrainRequestDelegate, progress: ToolCallProgressSink?) async throws -> Reply {
        let status = http?.statusCode ?? 0
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard (200..<300).contains(status), contentType.contains("text/event-stream"),
              var decoder = wire.makeStreamDecoder() else {
            var data = Data()
            for try await chunk in chunks { data.append(chunk) }
            try Task.checkCancellation()
            return Reply(status: status, outcome: .body(data))
        }
        var reader = ServerSentEventReader()
        func receive(_ event: ServerSentEvent) throws {
            delegate.mark("first_event_ms", elapsedMs: Self.elapsedMs(since: started))
            guard let delta = try decoder.receive(event), let progress else { return }
            for phase in progress(delta) {
                delegate.mark(phase, elapsedMs: Self.elapsedMs(since: started))
            }
        }
        do {
            // The terminal event ends the reply; a connection that stalls after it must not cost
            // the reply its deadline.
            chunks: for try await chunk in chunks {
                for event in reader.receive(chunk) {
                    try receive(event)
                    if decoder.isComplete { break chunks }
                }
            }
            if !decoder.isComplete {
                try Task.checkCancellation()
                if let trailing = reader.finish() { try receive(trailing) }
            }
            return Reply(status: status, outcome: .body(try decoder.finish()))
        } catch let failure as StreamFailure {
            return Reply(status: status, outcome: .failed(failure))
        }
    }

    /// One chunk per line: the event reader splits on newlines anyway, and an unstreamed body is
    /// one line. Cancelling the consumer cancels the byte task, which ends the request.
    private static func lineChunks(of bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                var line = Data()
                do {
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == UInt8(ascii: "\n") {
                            continuation.yield(line)
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
                bytes.task.cancel()
            }
        }
    }

    /// The first child to finish decides; leaving the group cancels the other.
    private static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func failure(httpStatus: Int, body: Data) -> ProviderFailure {
        classify(httpStatus: httpStatus, body: body, stage: .request)
    }

    /// The provider's error event reads through the same table as an error status; a stream that
    /// simply closed has nothing to read.
    private func failure(_ failure: StreamFailure, status: Int) -> ProviderFailure {
        guard let body = failure.errorBody else {
            return ProviderFailure(
                source: .brain(provider), stage: .response, category: .response, disposition: .temporary,
                identity: .init(httpStatus: status), message: "the reply ended before its terminal event")
        }
        return classify(httpStatus: status, body: body, stage: .response)
    }

    private func classify(httpStatus: Int, body: Data, stage: ProviderFailure.Stage) -> ProviderFailure {
        switch provider.descriptor.failureTable {
        case .openAI:
            OpenAIFailureClassifier.classify(
                httpStatus: httpStatus, body: body, source: .brain(provider), stage: stage)
        case .anthropic:
            AnthropicFailureClassifier.classify(
                httpStatus: httpStatus, body: body, source: .brain(provider), stage: stage)
        case .gemini:
            GeminiFailureClassifier.classify(
                httpStatus: httpStatus, body: body, source: .brain(provider), stage: stage)
        }
    }

    private static func elapsedMs(since started: Date) -> Int {
        Int(Date().timeIntervalSince(started) * 1000)
    }
}

/// One sink for every request of the attempt that owns the conversation.
private struct BrainAccessorConversation: BrainConversation {
    let accessor: BrainAccessor
    let progress: ToolCallProgressSink?

    func respond(messages: [ChatMessage], tools: [ToolDef],
                 toolChoice: ToolChoice) async throws -> BrainResponse {
        try await accessor.respond(messages: messages, tools: tools, toolChoice: toolChoice, progress: progress)
    }

    func finish() async {}
}
