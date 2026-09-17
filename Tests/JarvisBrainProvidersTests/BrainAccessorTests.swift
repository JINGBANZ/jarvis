import Foundation
import Testing
import JarvisBrainProviders
import JarvisCore
#if canImport(FoundationNetworking)
import FoundationNetworking   // HTTPURLResponse lives here off Darwin
#endif

private func http(_ code: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/responses")!,
                    statusCode: code, httpVersion: nil, headerFields: headers)!
}

private func speakResponseBody(arguments: String) -> Data {
    let item: [String: Any] = ["type": "function_call", "id": "f", "call_id": "c",
                               "name": "speak", "arguments": arguments]
    return try! JSONSerialization.data(withJSONObject: ["output": [item]])
}

@Suite struct BrainAccessorTests {
    @Test func decodesSpeakToolCallWithLinesArray() async throws {
        let json = """
        {"output":[
          {"type":"function_call","id":"fc_1","call_id":"call_1","name":"speak","arguments":"{\\"lines\\":[\\"Try a hash map.\\",\\"Use `Array.from({length: n + 1}, () => [])` instead.\\"]}"}
        ]}
        """
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        #expect(resp.toolCalls == [.speak(callId: "call_1",
            lines: ["Try a hash map.", "Use `Array.from({length: n + 1}, () => [])` instead."])])
    }

    @Test func decodesCaptureScreenToolCall() async throws {
        let json = """
        {"output":[
          {"type":"function_call","id":"fc_9","call_id":"call_9","name":"capture_screen","arguments":"{}"}
        ]}
        """
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        #expect(resp.toolCalls == [.captureScreen(callId: "call_9")])
        #expect(resp.rawToolCalls == [RawToolCall(id: "call_9", name: "capture_screen", argumentsJSON: "{}")])
    }

    @Test func decodeSurfacesWholeOutputVerbatim() async throws {
        let json = """
        {"output":[
          {"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"opaque-blob"},
          {"type":"function_call","id":"fc_9","call_id":"call_9","name":"capture_screen","arguments":"{}"}
        ]}
        """
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        #expect(resp.toolCalls == [.captureScreen(callId: "call_9")])
        #expect(resp.outputItemsJSON.count == 2)
        let reasoning = resp.outputItemsJSON.first ?? ""
        #expect(reasoning.contains(#""id":"rs_1""#))
        #expect(reasoning.contains(#""encrypted_content":"opaque-blob""#))
        let call = resp.outputItemsJSON.last ?? ""
        #expect(call.contains(#""id":"fc_9""#))
        #expect(call.contains(#""call_id":"call_9""#))
    }

    @Test func encodesRawItemsVerbatimBeforeFunctionCallOutput() async throws {
        let box = CapturedBody()
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        let convo: [ChatMessage] = [
            .user("transcript"),
            .rawItems([
                #"{"type":"reasoning","id":"rs_1","summary":[]}"#,
                #"{"type":"function_call","id":"fc_1","call_id":"call_1","name":"capture_screen","arguments":"{}"}"#,
            ], calls: [RawToolCall(id: "call_1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(role: .tool, text: "screenshot captured", toolCallId: "call_1"),
        ]
        _ = try await client.respond(messages: convo, tools: coachTools(detailEnabled: true))
        let body = try JSONSerialization.jsonObject(with: box.get() ?? Data()) as? [String: Any]
        let input = body?["input"] as? [[String: Any]] ?? []
        let kinds = input.map { ($0["type"] as? String) ?? ($0["role"] as? String) ?? "?" }
        #expect(kinds == ["user", "reasoning", "function_call", "function_call_output"])
        #expect(input.count == 4 && input[1]["id"] as? String == "rs_1")
        #expect(input.count == 4 && input[2]["id"] as? String == "fc_1")
    }

    @Test func decodesStaySilentToolCall() async throws {
        let json = """
        {"output":[
          {"type":"function_call","id":"fc_2","call_id":"call_2","name":"stay_silent","arguments":"{}"}
        ]}
        """
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        #expect(resp.toolCalls == [.staySilent(callId: "call_2")])
    }

    @Test func noToolCallsMeansSilent() async throws {
        let json = #"{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"(thinking)"}]}]}"#
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        #expect(resp.toolCalls.isEmpty)
    }

    /// Dropped, not decoded as an empty speak: an empty overlay would still count as a spoken turn.
    @Test func speakDecodeDropsOffContractArgumentsAsSilence() async throws {
        for args in [#"{}"#, #"{"lines":"hi"}"#, #"{"lines":[]}"#, #"{"lines":["  "]}"#, "not json"] {
            let body = speakResponseBody(arguments: args)
            let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                           send: { _ in (body, http(200)) })
            let resp = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
            #expect(resp.toolCalls.isEmpty, "args=\(args)")
        }
    }

    @Test func decodeFlagsIncompleteResponse() async throws {
        let json = #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        #expect(resp.toolCalls.isEmpty)
        #expect(resp.incompleteReason == "max_output_tokens")
    }

    @Test func decodeCompletedResponseHasNoIncompleteReason() async throws {
        let json = #"{"status":"completed","output":[{"type":"function_call","id":"f","call_id":"c","name":"speak","arguments":"{\"lines\":[\"hi\"]}"}]}"#
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        #expect(resp.incompleteReason == nil)
    }

    @Test func decodesOutputTextForToollessCalls() async throws {
        let json = #"{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"the "},{"type":"output_text","text":"summary"}]}]}"#
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.4-mini",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("condense this")], tools: [])
        #expect(resp.outputText == "the summary")
        #expect(resp.toolCalls.isEmpty)
    }

    @Test func openAIDefaultAndCompactionUseWorkloadDeadlines() async throws {
        let timeouts = CapturedTimeouts()
        let response = Data(#"{"output":[]}"#.utf8)
        let summarizer = BrainAccessor(
            apiKey: "sk-x",
            model: "gpt-5.4-mini",
            timeout: BrainWorkloadTimeout.historyCompaction,
            send: { request in
                timeouts.append(request.timeoutInterval)
                return (response, http(200))
            })
        let defaultClient = BrainAccessor(
            apiKey: "sk-x",
            model: "gpt-5.4-mini",
            send: { request in
                timeouts.append(request.timeoutInterval)
                return (response, http(200))
            })

        _ = try await summarizer.respond(messages: [.user("condense this")], tools: [])
        _ = try await defaultClient.respond(messages: [.user("condense this")], tools: [])

        #expect(BrainWorkloadTimeout.liveCoaching == 15)
        #expect(BrainWorkloadTimeout.historyCompaction == 45)
        #expect(timeouts.values == [
            BrainWorkloadTimeout.historyCompaction,
            BrainWorkloadTimeout.liveCoaching,
        ])
    }

    @Test func httpErrorThrowsWithoutRetry() async {
        let attempts = Counter()
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in _ = attempts.next(); return (Data("nope".utf8), http(400)) })
        await #expect(throws: (any Error).self) {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        }
        #expect(attempts.value == 1)
    }

    @Test func httpErrorIsClassifiedAtProviderBoundary() async {
        let client = BrainAccessor(
            apiKey: "sk-x", model: "gpt-5.5",
            send: { _ in (Data("unauthorized".utf8), http(401)) })
        do {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
            Issue.record("expected a classified HTTP failure")
        } catch let failure as ProviderFailure {
            #expect(failure.disposition == .permanent)
            #expect(failure.message.contains("unauthorized"))
            #expect(failure.identity.httpStatus == 401)
        } catch {
            Issue.record("expected ProviderFailure, got \(error)")
        }
    }

    @Test func unknownRequestLocalHTTPErrorPreservesTheSession() async {
        let body = Data(#"{"error":{"code":"future_request_error","type":"future_type"}}"#.utf8)
        let client = BrainAccessor(
            apiKey: "sk-x", model: "gpt-5.5",
            send: { _ in (body, http(422)) })
        do {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
            Issue.record("expected a classified HTTP failure")
        } catch let failure as ProviderFailure {
            #expect(failure.disposition == .temporary)
        } catch {
            Issue.record("expected ProviderFailure, got \(error)")
        }
    }

    @Test func generic404PreservesSessionButModelNotFoundStopsAtProviderBoundary() async {
        let cases: [(Data, ProviderFailure.Disposition)] = [
            (Data(#"{"error":{"message":"route unavailable"}}"#.utf8), .temporary),
            (Data(#"{"error":{"code":"model_not_found","type":"invalid_request_error"}}"#.utf8),
             .permanent),
        ]
        for (body, expected) in cases {
            let client = BrainAccessor(
                apiKey: "sk-x", model: "gpt-5.5",
                send: { _ in (body, http(404)) })
            do {
                _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
                Issue.record("expected a classified HTTP failure")
            } catch let failure as ProviderFailure {
                #expect(failure.disposition == expected)
            } catch {
                Issue.record("expected ProviderFailure, got \(error)")
            }
        }
    }

    @Test func parsedPermanentProviderCodeStopsEvenOnRateLimitStatus() async {
        let body = Data(#"{"error":{"code":"insufficient_quota","type":"billing_error"}}"#.utf8)
        let client = BrainAccessor(
            apiKey: "sk-x", model: "gpt-5.5",
            send: { _ in (body, http(429)) })
        do {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
            Issue.record("expected a classified HTTP failure")
        } catch let failure as ProviderFailure {
            #expect(failure.disposition == .permanent)
        } catch {
            Issue.record("expected ProviderFailure, got \(error)")
        }
    }

    /// `URLError.localizedDescription` embeds the failing URL, so it must never reach the message.
    @Test func transportFailuresCarryTheCodeAndNoURL() async {
        let client = BrainAccessor(
            apiKey: "sk-x", model: "gpt-5.5",
            send: { _ in throw URLError(.cannotConnectToHost) })
        do {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
            Issue.record("expected a classified transport failure")
        } catch let failure as ProviderFailure {
            #expect(failure.category == .unreachable)
            #expect(failure.disposition == .temporary)
            #expect(failure.identity.transportCode == URLError.cannotConnectToHost.rawValue)
            #expect(failure.message == "could not connect to the server")
        } catch {
            Issue.record("expected ProviderFailure, got \(error)")
        }
    }

    @Test func encodesResponsesRequestShape() async throws {
        let box = CapturedBody()
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5", reasoningEffort: "low",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        let convo: [ChatMessage] = [
            .system("be a coach"),
            .user("transcript"),
            .assistantToolCalls([RawToolCall(id: "call_1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(role: .tool, text: "screenshot captured", toolCallId: "call_1"),
            .userImage("ZmFrZQ=="),
        ]
        _ = try await client.respond(messages: convo, tools: coachTools(detailEnabled: true))
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"instructions\""))
        #expect(body.contains("\"function_call\""))
        #expect(body.contains("\"function_call_output\""))
        #expect(body.contains("\"call_id\":\"call_1\""))
        #expect(body.contains("\"input_image\""))
        #expect(body.contains("\"reasoning\""))
        #expect(body.contains("\"store\":true"))   // keeps requests inspectable in the OpenAI dashboard
        #expect(body.contains("\"max_output_tokens\""))
        #expect(body.contains("\"parallel_tool_calls\":false"))
        #expect(body.contains("\"name\":\"capture_screen\""))
    }

    /// A consumer subscription has no dashboard to inspect retained requests, so none are stored.
    @Test func aSubscriptionTargetAsksForNoRetention() async throws {
        let box = CapturedBody()
        let client = BrainAccessor(
            provider: .claudeSubscription, apiKey: "proxy-key", model: "claude-opus-5",
            reasoningEffort: "low",
            send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("transcript")], tools: coachTools(detailEnabled: true))
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"store\":false"))
    }

    @Test func aTargetSendsToItsOwnEndpointWithItsOwnKey() async throws {
        let box = CapturedRequest()
        let endpoint = URL(string: "http://127.0.0.1:52001/v1/responses")!
        let client = BrainAccessor(
            provider: .claudeSubscription, apiKey: "proxy-key", model: "claude-opus-5",
            endpoint: endpoint,
            send: { request in box.set(request); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        #expect(box.get()?.url == endpoint)
        #expect(box.get()?.value(forHTTPHeaderField: "Authorization") == "Bearer proxy-key")
    }

    @Test func aSubscriptionFailureNamesItsOwnProvider() async {
        let client = BrainAccessor(
            provider: .claudeSubscription, apiKey: "proxy-key", model: "claude-opus-5",
            send: { _ in (Data(#"{"error":{"message":"nope"}}"#.utf8), http(500)) })
        do {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
            Issue.record("expected the request to fail")
        } catch let failure as ProviderFailure {
            #expect(failure.source == .brain(.claudeSubscription))
        } catch {
            Issue.record("expected a ProviderFailure, got \(error)")
        }
    }

    @Test func everySelectableOpenAIModelRespectsItsEffortFloor() async throws {
        for model in BrainModelCatalog.models(for: .openAI) {
            for effort in ReasoningEffort.allCases {
                let box = CapturedBody()
                let client = BrainAccessor(
                    apiKey: "sk-x",
                    model: model.id,
                    reasoningEffort: effort.rawValue,
                    maxOutputTokens: effort.maxOutputTokens,
                    send: { request in
                        box.set(request.httpBody)
                        return (Data(#"{"output":[]}"#.utf8), http(200))
                    })
                _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
                let body = try #require(box.get())
                let request = try #require(
                    try JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(request["model"] as? String == model.id)
                #expect(
                    (request["reasoning"] as? [String: Any])?["effort"] as? String
                        == (model.id == "gpt-6-astra" && effort == .none ? "low" : effort.rawValue))
                #expect(request["max_output_tokens"] as? Int
                    == (model.id == "gpt-6-astra" && effort == .none
                        ? ReasoningEffort.low.maxOutputTokens : effort.maxOutputTokens))
            }
        }
    }

    @Test func astraClampsNoneWithoutReducingALargerOutputBudget() async throws {
        let box = CapturedBody()
        let client = BrainAccessor(
            apiKey: "sk-x", model: "gpt-6-astra", reasoningEffort: "none",
            maxOutputTokens: 25_000,
            send: { request in
                box.set(request.httpBody)
                return (Data(#"{"output":[]}"#.utf8), http(200))
            })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        let body = try #require(box.get())
        let request = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((request["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        #expect(request["max_output_tokens"] as? Int == 25_000)
    }

    @Test func encodesProvidedMaxOutputTokens() async throws {
        let box = CapturedBody()
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5", maxOutputTokens: 25_000,
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"max_output_tokens\":25000"))
    }

    @Test func defaultMaxOutputTokensTracksDefaultEffort() async throws {
        let box = CapturedBody()
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"max_output_tokens\":\(Defaults.Brain.effort.maxOutputTokens)"))
    }

    @Test func encodesStrictToolsForStructuredOutput() async throws {
        let box = CapturedBody()
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"strict\":true"))
    }

    @Test func encodesTheLoaderAndDeclaresADeferredToolOnlyOnceLoaded() async throws {
        let capabilities = CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: true)
        let box = CapturedBody()
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })

        _ = try await client.respond(messages: [.user("hi")], tools: capabilities.callable(loaded: []))
        let before = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(before.contains("\"load_tool\""))
        #expect(before.contains("\"enum\":[\"search_prep_notes\"]"))
        #expect(before.contains("\"strict\":true"))
        #expect(!before.contains("\"name\":\"search_prep_notes\""))

        _ = try await client.respond(
            messages: [.user("hi")],
            tools: capabilities.callable(loaded: ["search_prep_notes"]))
        let after = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(after.contains("\"name\":\"search_prep_notes\""))
    }

    @Test func encodesTheSkillLoaderWithItsCatalogEnum() async throws {
        let capabilities = CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: false,
            skills: [Skill(name: "behavioral", description: "d", body: "b"),
                     Skill(name: "system-design", description: "d", body: "b")])
        let box = CapturedBody()
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })

        _ = try await client.respond(messages: [.user("hi")], tools: capabilities.callable(loaded: []))

        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"load_skill\""))
        #expect(body.contains("\"enum\":[\"behavioral\",\"system-design\"]"))
        #expect(body.contains("\"strict\":true"))
        #expect(!body.contains("\"load_tool\""))
    }

    @Test func aConversationDeclaresEachRequestsOwnTools() async throws {
        let capabilities = CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: true)
        let box = CapturedBody()
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        let conversation = try await client.makeConversation()

        _ = try await conversation.respond(
            messages: [.user("hi")], tools: capabilities.callable(loaded: []),
            toolChoice: .required)
        #expect(!(String(data: box.get() ?? Data(), encoding: .utf8) ?? "")
            .contains("\"name\":\"search_prep_notes\""))

        _ = try await conversation.respond(
            messages: [.user("hi")], tools: capabilities.callable(loaded: ["search_prep_notes"]),
            toolChoice: .required)
        #expect((String(data: box.get() ?? Data(), encoding: .utf8) ?? "")
            .contains("\"name\":\"search_prep_notes\""))
        await conversation.finish()
    }

    @Test func defaultToolChoiceIsAuto() async throws {
        let box = CapturedBody()
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"tool_choice\":\"auto\""))
    }

    @Test func requiredToolChoiceEncodesRequiredString() async throws {
        let box = CapturedBody()
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true), toolChoice: .required)
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"tool_choice\":\"required\""))
    }

    @Test func forceToolChoiceEncodesFunctionObject() async throws {
        let box = CapturedBody()
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true), toolChoice: .force("speak"))
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"tool_choice\""))
        #expect(body.contains("\"type\":\"function\""))
        #expect(body.contains("\"name\":\"speak\""))
    }

    /// The declared array must match the `.required` request's so the prompt-cache prefix is
    /// unchanged.
    @Test func allowedToolChoiceEncodesAllowedToolsOverTheSameDeclaredArray() async throws {
        let tools = CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: false,
            skills: [Skill(name: "behavioral", description: "d", body: "b")]).tools
        let box = CapturedBody()
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: tools, toolChoice: .required)
        let required = try #require(
            try JSONSerialization.jsonObject(with: box.get() ?? Data()) as? [String: Any])
        _ = try await client.respond(messages: [.user("hi")], tools: tools,
                                     toolChoice: .allowed(["speak", "load_skill"]))
        let allowed = try #require(
            try JSONSerialization.jsonObject(with: box.get() ?? Data()) as? [String: Any])

        let choice = try #require(allowed["tool_choice"] as? [String: Any])
        #expect(choice["type"] as? String == "allowed_tools")
        #expect(choice["mode"] as? String == "required")
        #expect(choice["tools"] as? [[String: String]] == [
            ["type": "function", "name": "speak"],
            ["type": "function", "name": "load_skill"],
        ])
        #expect(allowed["tools"] as? NSArray == required["tools"] as? NSArray)
    }

    private func encodedBody(
        policy: ToolChoicePolicy, tools: [ToolDef], choice: ToolChoice,
        effort: String = "low", maxOutputTokens: Int = 2_048, floor: ReasoningEffort? = nil
    ) async throws -> [String: Any] {
        let box = CapturedBody()
        let client = BrainAccessor(
            apiKey: "sk-x", model: "claude-opus-5", reasoningEffort: effort,
            maxOutputTokens: maxOutputTokens, toolChoicePolicy: policy,
            minimumReasoningEffort: floor,
            send: { request in
                box.set(request.httpBody)
                return (Data(#"{"output":[]}"#.utf8), http(200))
            })
        _ = try await client.respond(messages: [.user("hi")], tools: tools, toolChoice: choice)
        return try #require(
            try JSONSerialization.jsonObject(with: box.get() ?? Data()) as? [String: Any])
    }

    private var fiveTools: [ToolDef] {
        CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: true,
            skills: [Skill(name: "behavioral", description: "d", body: "b")]).callable(loaded: [])
    }

    private func declaredNames(_ body: [String: Any]) -> [String]? {
        (body["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
    }

    /// Strict tools and `parallel_tool_calls` still go out; the proxy strips what it cannot
    /// forward.
    @Test func filteredAutoDeclaresOnlyTheAllowedToolsInCatalogOrder() async throws {
        let tools = fiveTools
        #expect(tools.count == 5)
        let body = try await encodedBody(
            policy: .filteredAuto, tools: tools, choice: .allowed(["load_tool", "speak"]))
        #expect(declaredNames(body) == tools.map(\.name).filter { $0 == "speak" || $0 == "load_tool" })
        #expect(body["tool_choice"] as? String == "auto")
        #expect(body["parallel_tool_calls"] as? Bool == false)
        #expect((body["tools"] as? [[String: Any]])?.allSatisfy { $0["strict"] as? Bool == true } == true)
    }

    @Test func filteredAutoForcesByDeclaringOnlyTheForcedTool() async throws {
        let body = try await encodedBody(policy: .filteredAuto, tools: fiveTools, choice: .force("speak"))
        #expect(declaredNames(body) == ["speak"])
        #expect(body["tool_choice"] as? String == "auto")
    }

    @Test func filteredAutoRequiresByDeclaringEveryTool() async throws {
        let tools = fiveTools
        let body = try await encodedBody(policy: .filteredAuto, tools: tools, choice: .required)
        #expect(declaredNames(body) == tools.map(\.name))
        #expect(body["tool_choice"] as? String == "auto")
    }

    @Test func aReasoningFloorRaisesOnlyAShallowerEffort() async throws {
        let raised = try await encodedBody(
            policy: .filteredAuto, tools: fiveTools, choice: .required,
            effort: "none", maxOutputTokens: 1_024, floor: .low)
        #expect((raised["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        #expect(raised["max_output_tokens"] as? Int == 2_048)

        let kept = try await encodedBody(
            policy: .filteredAuto, tools: fiveTools, choice: .required,
            effort: "medium", maxOutputTokens: 8_192, floor: .low)
        #expect((kept["reasoning"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(kept["max_output_tokens"] as? Int == 8_192)
    }

    @Test func successfulRoundTripIsRecordedToTrafficLog() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = await FileSessionAudit.readyForTesting(directory: dir)
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       traffic: traffic, trafficTag: "coach",
                                       send: { _ in (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        _ = await traffic.closeForTesting()

        let text = try String(contentsOf: dir.appendingPathComponent(FileSessionAudit.brainTrafficFilename),
                              encoding: .utf8)
        let entry = try #require(try JSONSerialization.jsonObject(
            with: Data(text.split(separator: "\n")[0].utf8)) as? [String: Any])
        #expect(entry["tag"] as? String == "coach")
        #expect(entry["status"] as? Int == 200)
        #expect((entry["request"] as? [String: Any])?["model"] as? String == "gpt-5.5")
        #expect(entry["response"] != nil)
    }

    @Test func transportErrorIsRecordedToTrafficLogAndRethrown() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = await FileSessionAudit.readyForTesting(directory: dir)
        let client = BrainAccessor(apiKey: "sk-x", model: "gpt-5.5",
                                       traffic: traffic, trafficTag: "coach",
                                       send: { _ in throw URLError(.timedOut) })
        await #expect(throws: (any Error).self) {
            try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        }
        _ = await traffic.closeForTesting()
        let text = try String(contentsOf: dir.appendingPathComponent(FileSessionAudit.brainTrafficFilename),
                              encoding: .utf8)
        let entry = try #require(try JSONSerialization.jsonObject(
            with: Data(text.split(separator: "\n")[0].utf8)) as? [String: Any])
        #expect(entry["error"] != nil)
        #expect(entry["response"] == nil)
        #expect((entry["request"] as? [String: Any])?["model"] as? String == "gpt-5.5")
    }

    @Test func geminiTargetsSendTheKeyInItsHeaderOnly() async throws {
        let captured = CapturedRequests()
        let client = BrainAccessor(
            provider: .gemini, apiKey: "AIzaTestKey", model: "gemini-3.8-flash",
            endpoint: BrainProviderDescriptor.geminiInteractionsEndpoint,
            send: { request in
                captured.append(request)
                return (Data(#"{"status":"completed","steps":[]}"#.utf8), http(200))
            })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
        let request = try #require(captured.values.first)
        #expect(request.url == BrainProviderDescriptor.geminiInteractionsEndpoint)
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "AIzaTestKey")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["store"] as? Bool == false)
        #expect(body["generation_config"] != nil)
    }

    @Test func aRejectedGeminiKeyIsPermanent() async throws {
        let client = BrainAccessor(
            provider: .gemini, apiKey: "AIzaTestKey", model: "gemini-3.8-flash",
            endpoint: BrainProviderDescriptor.geminiInteractionsEndpoint,
            send: { _ in
                (Data(#"[{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}]"#.utf8), http(400))
            })
        do {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools(detailEnabled: true))
            Issue.record("a rejected key must throw")
        } catch let failure as ProviderFailure {
            #expect(failure.source == .brain(.gemini))
            #expect(failure.category == .authentication && failure.disposition == .permanent)
        }
    }
}

// @unchecked: all mutable state is guarded by lock.
final class CapturedRequest: @unchecked Sendable {
    private var request: URLRequest?
    private let lock = NSLock()
    func set(_ r: URLRequest) { lock.lock(); request = r; lock.unlock() }
    func get() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return request }
}

// @unchecked: all mutable state is guarded by lock.
final class CapturedBody: @unchecked Sendable {
    private var data: Data?
    private let lock = NSLock()
    func set(_ d: Data?) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
}

// @unchecked: all mutable state is guarded by lock.
final class CapturedTimeouts: @unchecked Sendable {
    private var recorded: [TimeInterval] = []
    private let lock = NSLock()
    func append(_ timeout: TimeInterval) { lock.lock(); recorded.append(timeout); lock.unlock() }
    var values: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return recorded }
}

// @unchecked: all mutable state is guarded by lock.
final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; let v = n; n += 1; return v }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
