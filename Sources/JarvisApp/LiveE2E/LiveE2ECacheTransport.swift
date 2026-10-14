#if JARVIS_LIVE_E2E
import Foundation
import JarvisBrainProviders
import JarvisCore

enum LiveE2ECacheTransport {
    static func sender(
        provider: BrainProvider, budget: LiveE2ECacheBudget, supervisor: LocalProxySupervisor
    ) -> BrainAccessor.Sender {
        { request in
            let endpoint: URL
            switch provider {
            case .openAI:
                endpoint = BrainProviderDescriptor.openAIResponsesEndpoint
            case .codexSubscription:
                guard case .running(let proxy) = await supervisor.state else {
                    throw LiveE2ECacheBudget.Failure.exhausted("subscription helper is not running")
                }
                endpoint = proxy.responsesURL
            default:
                throw LiveE2ECacheBudget.Failure.exhausted("cache scenario requires a Responses target")
            }
            guard let body = request.httpBody,
                  let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw LiveE2ECacheBudget.Failure.exhausted("missing request body")
            }
            let exchange = RecordedExchange.read(request: object, response: nil)
            guard exchange.model == LiveE2EScenario.target(for: provider).modelID,
                  request.url == endpoint,
                  object["max_output_tokens"] as? Int == LiveE2ECacheBudget.maximumOutputTokens,
                  object["service_tier"] == nil || object["service_tier"] as? String == "default" else {
                throw LiveE2ECacheBudget.Failure.exhausted("cache scenario changed its target, client output cap or tier")
            }
            try await budget.reserve(inputBytes: body.count)
            let (bytes, response) = try await URLSession.shared.bytes(
                for: request, delegate: LiveE2ECacheRedirectPolicy())
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                let task = Task {
                    do {
                        var line = Data()
                        for try await byte in bytes {
                            try Task.checkCancellation()
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
                    task.cancel()
                    bytes.task.cancel()
                }
            }
            return (stream, response as? HTTPURLResponse)
        }
    }
}
#endif
