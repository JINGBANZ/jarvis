import Foundation

/// Evidence required before the app-server implementation may launch. Feature discovery is
/// deliberately not evidence: it can only name the current catalog and therefore fails open when
/// the probe fails or a future built-in family appears.
enum CodexBuiltInToolIsolation: Sendable, Equatable {
    case unavailable
    /// Reserved for a future stable provider control whose documented semantics remove every
    /// built-in tool. Keeping its arguments here couples that proof to the launched process.
    case toolFree(launchArguments: [String])
}

/// One Codex app-server for the live Jarvis session. Each coaching attempt gets a fresh ephemeral
/// thread; every model turn in that attempt stays on the thread and receives only incremental input.
actor CodexAppServerRuntime: LocalAgentRuntimeBackend {
    /// Thread teardown is best-effort cleanup, not model inference. A wedged unsubscribe must not
    /// hold the attempt open for the turn's much longer response deadline.
    private static let threadCleanupTimeout: TimeInterval = 1
    private static let allowedItemDeltaMethods: Set<String> = [
        "item/agentMessage/delta",
        "item/reasoning/summaryPartAdded",
        "item/reasoning/summaryTextDelta",
        "item/reasoning/textDelta",
    ]
    private static let allowedItemTypes: Set<String> = [
        "userMessage",
        "agentMessage",
        "reasoning",
    ]

    private struct Preparation: Sendable {
        let id: UUID
        let task: Task<CodexAppServer, Error>
    }

    fileprivate struct LaunchIdentity: Equatable {
        let executable: URL
        let workDirectory: URL
        let supportedFeatures: Set<String>
        let toolIsolationArguments: [String]
    }

    private let runtimeBaseDirectory: URL
    private let supportedFeatures: Set<String>
    private let builtInToolIsolation: CodexBuiltInToolIsolation
    private let lifetime = AgentRuntimeLifetime()
    private var identity: LaunchIdentity?
    private var server: CodexAppServer?
    private var preparing: Preparation?
    private var nextRequestID = 0
    private var activeThreadID: String?

    init(
        runtimeBaseDirectory: URL = CodexRuntimeHome.defaultBaseDirectory,
        supportedFeatures: Set<String> = [],
        builtInToolIsolation: CodexBuiltInToolIsolation = .unavailable
    ) {
        self.runtimeBaseDirectory = runtimeBaseDirectory
        self.supportedFeatures = supportedFeatures
        self.builtInToolIsolation = builtInToolIsolation
    }

    func prepare(for configuration: LocalAgentConversationConfiguration) async throws {
        guard configuration.provider == .codexCLI else {
            preconditionFailure("CodexAppServerRuntime received \(configuration.provider)")
        }
        guard case .toolFree(let toolIsolationArguments) = builtInToolIsolation else {
            throw BrainFailure(
                disposition: .permanent,
                detail: DetectedAgentCLI.codexToolFreeModeUnavailableDetail)
        }
        let requested = LaunchIdentity(
            executable: configuration.executable,
            workDirectory: configuration.workDirectory,
            supportedFeatures: supportedFeatures,
            toolIsolationArguments: toolIsolationArguments)
        if let identity, identity != requested {
            throw Self.error("a session-scoped Codex app-server cannot change its launch identity")
        }
        identity = requested
        if let server, server.isRunning {
            return
        }
        server = nil
        if preparing == nil {
            let lifetime = self.lifetime
            let runtimeBaseDirectory = self.runtimeBaseDirectory
            preparing = Preparation(
                id: UUID(),
                task: Task.detached(priority: .utility) {
                    try await CodexAppServer.start(
                        identity: requested,
                        runtimeBaseDirectory: runtimeBaseDirectory,
                        timeout: configuration.timeout,
                        lifetime: lifetime)
                })
        }
        guard let preparation = preparing else {
            throw Self.error("Codex app-server preparation was unavailable")
        }
        do {
            let preparedServer = try await awaitPreparation(preparation)
            if preparing?.id == preparation.id {
                server = preparedServer
                preparing = nil
            }
        } catch {
            if preparing?.id == preparation.id {
                preparing = nil
            }
            throw error
        }
    }

    func openConversation(for configuration: LocalAgentConversationConfiguration)
        async throws -> any LocalAgentConversation {
        try await prepare(for: configuration)
        guard let server else { throw Self.error("Codex app-server was not ready") }
        guard activeThreadID == nil else {
            throw Self.error("Codex app-server already has an active coaching conversation")
        }
        do {
            let requestID = takeRequestID()
            let deadline = Date().addingTimeInterval(configuration.timeout)
            var parameters: [String: Any] = [
                "cwd": configuration.workDirectory.path,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "ephemeral": true,
                "baseInstructions": CLIBrainClient.codexDirectResponseInstruction
                    + "\n\n" + configuration.instructions,
                "config": [
                    "mcp_servers": [:],
                    "project_root_markers": [],
                    "project_doc_max_bytes": 0,
                    "model_reasoning_effort":
                        CLIBrainClient.codexEffort(configuration.reasoningEffort),
                ],
            ]
            if !configuration.model.isEmpty {
                parameters["model"] = configuration.model
            }
            try await server.send(
                method: "thread/start",
                parameters: parameters,
                id: requestID,
                timeout: max(0.01, deadline.timeIntervalSinceNow))
            let result = try await waitForResponse(
                id: requestID,
                server: server,
                deadline: deadline)
            guard let thread = result["thread"] as? [String: Any],
                  let threadID = thread["id"] as? String else {
                throw Self.error("Codex thread/start returned no thread")
            }
            let instructionSources = result["instructionSources"] as? [Any] ?? []
            guard thread["ephemeral"] as? Bool == true,
                  thread["path"] == nil || thread["path"] is NSNull,
                  instructionSources.isEmpty else {
                throw Self.error(
                    "Codex returned a non-ephemeral or instruction-loaded thread: "
                    + Self.jsonDescription(result))
            }
            activeThreadID = threadID
            return CodexAppServerConversation(
                runtime: self,
                threadID: threadID,
                configuration: configuration)
        } catch {
            invalidate(server)
            throw error
        }
    }

    nonisolated func terminateNow() {
        lifetime.terminateAll()
    }

    private func awaitPreparation(_ preparation: Preparation) async throws -> CodexAppServer {
        let lifetime = self.lifetime
        return try await withTaskCancellationHandler {
            try await preparation.task.value
        } onCancel: {
            preparation.task.cancel()
            lifetime.terminateAll()
        }
    }

    fileprivate func respond(
        threadID: String,
        configuration: LocalAgentConversationConfiguration,
        turn: LocalAgentTurn
    ) async throws -> LocalAgentTurnResult {
        guard let server, server.isRunning else {
            throw Self.error("Codex app-server stopped before the turn")
        }
        guard activeThreadID == threadID else {
            throw Self.error("Codex conversation is no longer active")
        }
        var transientFiles: [URL] = []
        defer {
            for file in transientFiles {
                try? FileManager.default.removeItem(at: file)
            }
        }

        do {
            var input: [[String: Any]] = []
            for item in turn.input {
                switch item {
                case .text(let text):
                    input.append(["type": "text", "text": text])
                case .imageJPEG(let base64):
                    let file = try writeImage(base64, in: configuration.workDirectory)
                    transientFiles.append(file)
                    input.append(["type": "localImage", "path": file.path])
                }
            }

            let requestID = takeRequestID()
            let dispatchedAt = DispatchTime.now().uptimeNanoseconds
            let deadline = Date().addingTimeInterval(turn.timeout)
            try await server.send(
                method: "turn/start",
                parameters: [
                    "threadId": threadID,
                    "input": input,
                    "effort": CLIBrainClient.codexEffort(configuration.reasoningEffort),
                ],
                id: requestID,
                timeout: max(0.01, deadline.timeIntervalSinceNow))

            var firstAssistantAt: UInt64?
            var completedText: String?
            var fragments: [String] = []
            while true {
                let line = try await server.nextLine(deadline: deadline)
                guard let payload = Self.object(from: line.text) else { continue }
                if payload["id"] as? Int == requestID, let rpcError = payload["error"] {
                    throw Self.error("Codex turn/start failed: \(Self.jsonDescription(rpcError))")
                }

                let method = payload["method"] as? String
                let parameters = payload["params"] as? [String: Any]
                if Self.isServerRequest(payload) {
                    throw Self.error(
                        "Codex emitted an unexpected server request in a decision-only turn")
                }
                if let notificationThread = parameters?["threadId"] as? String,
                   notificationThread != threadID {
                    continue
                }

                if Self.isDisallowedItemEvent(method: method, parameters: parameters) {
                    throw Self.error(
                        "Codex emitted a disallowed item event in a decision-only turn")
                }
                if Self.isAgentMessage(method: method, parameters: parameters),
                   firstAssistantAt == nil {
                    firstAssistantAt = line.observedAt
                }
                if method == "item/agentMessage/delta",
                   let delta = parameters?["delta"] as? String {
                    fragments.append(delta)
                } else if method == "item/completed",
                          let item = parameters?["item"] as? [String: Any],
                          item["type"] as? String == "agentMessage",
                          let text = item["text"] as? String {
                    completedText = text
                }

                guard method == "turn/completed" else { continue }
                let completedAt = line.observedAt
                let completedTurn = parameters?["turn"] as? [String: Any]
                if let items = completedTurn?["items"] as? [[String: Any]],
                   items.contains(where: { !Self.isAllowedItemType($0["type"] as? String) }) {
                    throw Self.error(
                        "Codex completed a decision-only turn with a disallowed item")
                }
                guard completedTurn?["status"] as? String == "completed" else {
                    let detail = completedTurn?["error"]
                        .map(Self.jsonDescription) ?? "Codex turn did not complete"
                    throw Self.error(detail)
                }
                return LocalAgentTurnResult(
                    reply: completedText ?? fragments.joined(),
                    metadata: completedTurn.flatMap {
                        try? JSONSerialization.data(withJSONObject: $0)
                    },
                    dispatchedAt: dispatchedAt,
                    firstAssistantAt: firstAssistantAt,
                    completedAt: completedAt)
            }
        } catch {
            invalidate(server)
            throw error
        }
    }

    fileprivate func unsubscribe(threadID: String) async {
        guard activeThreadID == threadID else { return }
        defer {
            if activeThreadID == threadID {
                activeThreadID = nil
            }
        }
        guard let server, server.isRunning else { return }
        do {
            let requestID = takeRequestID()
            let deadline = Date().addingTimeInterval(Self.threadCleanupTimeout)
            try await server.send(
                method: "thread/unsubscribe",
                parameters: ["threadId": threadID],
                id: requestID,
                timeout: max(0.01, deadline.timeIntervalSinceNow))
            _ = try await waitForResponse(
                id: requestID,
                server: server,
                deadline: deadline)
        } catch {
            jlog("Jarvis: Codex thread unsubscribe failed: \(error.localizedDescription)")
            invalidate(server)
        }
    }

    private func waitForResponse(
        id: Int,
        server: CodexAppServer,
        deadline: Date
    ) async throws -> [String: Any] {
        while true {
            let line = try await server.nextLine(deadline: deadline)
            guard let payload = Self.object(from: line.text) else {
                continue
            }
            if Self.isServerRequest(payload) {
                throw Self.error("Codex emitted an unexpected server request")
            }
            guard payload["id"] as? Int == id else {
                continue
            }
            if let rpcError = payload["error"] {
                throw Self.error("Codex app-server request failed: "
                                 + Self.jsonDescription(rpcError))
            }
            return payload["result"] as? [String: Any] ?? [:]
        }
    }

    private func takeRequestID() -> Int {
        nextRequestID += 1
        return nextRequestID
    }

    private func invalidate(_ server: CodexAppServer) {
        guard self.server === server else { return }
        server.finish()
        self.server = nil
        activeThreadID = nil
    }

    private func writeImage(_ base64: String, in directory: URL) throws -> URL {
        guard let data = Data(base64Encoded: base64) else {
            throw Self.error("screenshot payload was not valid base64")
        }
        let url = directory.appendingPathComponent(
            "cli-shot-\(UUID().uuidString.prefix(8)).jpg")
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]) else {
            throw Self.error("couldn't write screenshot for Codex at \(url.path)")
        }
        return url
    }

    private static func object(from line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    fileprivate static func isServerRequest(_ payload: [String: Any]) -> Bool {
        payload["method"] != nil
            && payload["id"] != nil
            && !(payload["id"] is NSNull)
    }

    private static func isAgentMessage(method: String?,
                                       parameters: [String: Any]?) -> Bool {
        if method == "item/agentMessage/delta" { return true }
        guard method == "item/started" || method == "item/completed",
              let item = parameters?["item"] as? [String: Any] else {
            return false
        }
        return item["type"] as? String == "agentMessage"
    }

    /// The app-server schema grows new tool item types over time. Keep a narrow allowlist for the
    /// message/reasoning events a decision-only turn needs rather than chasing tool names.
    private static func isDisallowedItemEvent(
        method: String?,
        parameters: [String: Any]?
    ) -> Bool {
        guard let method, method.hasPrefix("item/") else { return false }
        if allowedItemDeltaMethods.contains(method) {
            return false
        }
        if method == "item/started" || method == "item/completed" {
            guard let item = parameters?["item"] as? [String: Any],
                  let type = item["type"] as? String else {
                return true
            }
            return !isAllowedItemType(type)
        }
        return true
    }

    private static func isAllowedItemType(_ type: String?) -> Bool {
        guard let type else { return false }
        return allowedItemTypes.contains(type)
    }

    fileprivate static func jsonDescription(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object))
            .map { String(decoding: $0, as: UTF8.self) } ?? String(describing: object)
    }

    fileprivate static func error(_ detail: String) -> NSError {
        NSError(domain: "CodexAppServerRuntime", code: 1,
                userInfo: [NSLocalizedDescriptionKey: detail])
    }
}

/// `@unchecked Sendable` is justified because `lock` guards the only mutable property, `finished`;
/// the actor reference and immutable thread/configuration values are Sendable.
private final class CodexAppServerConversation: LocalAgentConversation, @unchecked Sendable {
    private let runtime: CodexAppServerRuntime
    private let threadID: String
    private let configuration: LocalAgentConversationConfiguration
    private let lock = NSLock()
    private var finished = false

    init(runtime: CodexAppServerRuntime, threadID: String,
         configuration: LocalAgentConversationConfiguration) {
        self.runtime = runtime
        self.threadID = threadID
        self.configuration = configuration
    }

    deinit {
        if claimFinish() {
            let runtime = self.runtime
            let threadID = self.threadID
            Task.detached {
                await runtime.unsubscribe(threadID: threadID)
            }
        }
    }

    func respond(to turn: LocalAgentTurn) async throws -> LocalAgentTurnResult {
        try await runtime.respond(
            threadID: threadID,
            configuration: configuration,
            turn: turn)
    }

    func finish() async {
        guard claimFinish() else { return }
        await runtime.unsubscribe(threadID: threadID)
    }

    private func claimFinish() -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        lock.unlock()
        return true
    }
}

/// `@unchecked Sendable` is justified because `lock` guards the only mutable property, `finished`;
/// the process and lifetime references provide their own synchronization.
private final class CodexAppServer: @unchecked Sendable {
    private let process: AgentRuntimeProcess
    private let lifetime: AgentRuntimeLifetime
    private let runtimeHome: URL
    private let lock = NSLock()
    private var finished = false

    private init(process: AgentRuntimeProcess, lifetime: AgentRuntimeLifetime,
                 runtimeHome: URL) {
        self.process = process
        self.lifetime = lifetime
        self.runtimeHome = runtimeHome
    }

    deinit {
        finish()
    }

    var isRunning: Bool { process.isRunning }

    static func start(identity: CodexAppServerRuntime.LaunchIdentity,
                      runtimeBaseDirectory: URL,
                      timeout: TimeInterval,
                      lifetime: AgentRuntimeLifetime) async throws -> CodexAppServer {
        let runtimeHome = try CodexRuntimeHome.create(in: runtimeBaseDirectory)
        var didStart = false
        defer {
            if !didStart {
                try? FileManager.default.removeItem(at: runtimeHome)
            }
        }
        var arguments = [
            "app-server", "--stdio",
            "-c", "mcp_servers={}",
            "-c", "project_root_markers=[]",
            "-c", "project_doc_max_bytes=0",
        ] + identity.toolIsolationArguments
        for feature in CLIBrainClient.codexDisabledAgentFeatures
        where identity.supportedFeatures.contains(feature) {
            arguments += ["--disable", feature]
        }

        let process = try AgentRuntimeProcess(
            executable: identity.executable,
            arguments: arguments,
            workingDirectory: identity.workDirectory,
            environmentOverrides: ["CODEX_HOME": runtimeHome.path])
        do {
            try lifetime.register(process)
            let server = CodexAppServer(
                process: process,
                lifetime: lifetime,
                runtimeHome: runtimeHome)
            let deadline = Date().addingTimeInterval(timeout)
            try await server.send(
                method: "initialize",
                parameters: [
                    "clientInfo": [
                        "name": "jarvis",
                        "title": "Jarvis",
                        "version": "0.1",
                    ],
                ],
                id: 0,
                timeout: max(0.01, deadline.timeIntervalSinceNow))
            while true {
                let line = try await server.nextLine(deadline: deadline)
                guard let payload = try JSONSerialization.jsonObject(
                    with: Data(line.text.utf8)) as? [String: Any] else {
                    continue
                }
                if CodexAppServerRuntime.isServerRequest(payload) {
                    throw CodexAppServerRuntime.error(
                        "Codex emitted an unexpected server request during initialize")
                }
                guard payload["id"] as? Int == 0 else {
                    continue
                }
                if let rpcError = payload["error"] {
                    throw CodexAppServerRuntime.error(
                        "Codex initialize failed: "
                        + CodexAppServerRuntime.jsonDescription(rpcError))
                }
                break
            }
            try await server.send(
                method: "initialized",
                parameters: nil,
                id: nil,
                timeout: max(0.01, deadline.timeIntervalSinceNow))
            let readyMs = Int(
                (DispatchTime.now().uptimeNanoseconds - process.launchedAt) / 1_000_000)
            jlog("Jarvis: Codex app-server ready in \(readyMs)ms")
            didStart = true
            return server
        } catch {
            lifetime.unregister(process)
            process.terminateNow()
            throw error
        }
    }

    func send(
        method: String,
        parameters: [String: Any]?,
        id: Int?,
        timeout: TimeInterval
    ) async throws {
        var object: [String: Any] = ["method": method]
        if let parameters { object["params"] = parameters }
        if let id { object["id"] = id }
        try await process.sendJSONObject(object, timeout: timeout)
    }

    func nextLine(deadline: Date) async throws -> AgentRuntimeProcess.Line {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            process.terminateNow()
            throw NSError(
                domain: "CodexAppServerRuntime",
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "Codex app-server response timed out"])
        }
        return try await process.nextLine(timeout: remaining)
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        process.terminateNow()
        lifetime.unregister(process)
        try? FileManager.default.removeItem(at: runtimeHome)
    }
}
