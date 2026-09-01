import Foundation
import JarvisCore

/// One Codex app-server for the live Jarvis session. Session Start prepares the first target-specific
/// ephemeral thread; each later coaching attempt gets another fresh thread. Every model turn in an
/// attempt stays on its thread and receives only incremental input.
///
/// Codex exposes no control that removes every built-in tool (`codex app-server --help` and the
/// generated `ThreadStartParams` schema on 0.145.0 have no such flag or field), so isolation is the
/// same layered envelope `codex exec` coaching used: read-only sandbox, never-approval, an ephemeral
/// thread verified to have loaded no instruction sources, empty MCP config, zero project-doc bytes,
/// a private `CODEX_HOME`, the advertised-feature disable set, and a prompt forbidding built-in tool
/// use. On top of that this runtime rejects any server request or item event outside the
/// message/reasoning allowlist, which catches built-in families the disable list never named.
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
    private static let terminalTurnStatuses: Set<String> = [
        "completed",
        "interrupted",
        "failed",
    ]

    /// The turn exceeded its workload deadline, but Codex confirmed a scoped interrupt and terminal
    /// turn state. The caller may retire the thread without tearing down the healthy app-server.
    private struct RecoveredTurnTimeout: LocalizedError {
        let seconds: TimeInterval

        var errorDescription: String? {
            "Codex turn timed out after \(seconds)s"
        }
    }

    private struct ServerPreparation: Sendable {
        let id: UUID
        let task: Task<CodexAppServer, Error>
    }

    private struct PreparedThread: Sendable {
        let id: String
        let configuration: LocalAgentConversationConfiguration
    }

    private struct ThreadPreparation: Sendable {
        let id: UUID
        let configuration: LocalAgentConversationConfiguration
        let task: Task<PreparedThread, Error>
    }

    fileprivate struct LaunchIdentity: Equatable {
        let executable: URL
        let workDirectory: URL
        let supportedFeatures: Set<String>
    }

    nonisolated let transport = LocalAgentTransport.appServer
    private let runtimeBaseDirectory: URL
    private let supportedFeatures: Set<String>
    private let lifetime = AgentRuntimeLifetime()
    private var identity: LaunchIdentity?
    private var server: CodexAppServer?
    private var preparingServer: ServerPreparation?
    private var preparedThread: PreparedThread?
    private var preparingThread: ThreadPreparation?
    /// Ordering for `prepareThread`'s replacement rule: the newest thread request, and how many
    /// attempts are opening a conversation right now.
    private var latestThreadRequest = 0
    private var openingConversations = 0
    private var nextRequestID = 0
    private var activeThreadID: String?

    init(
        runtimeBaseDirectory: URL = CodexRuntimeHome.defaultBaseDirectory,
        supportedFeatures: Set<String> = []
    ) {
        self.runtimeBaseDirectory = runtimeBaseDirectory
        self.supportedFeatures = supportedFeatures
    }

    /// Opportunistic warm-up: prepares a thread for `configuration` unless an attempt is opening a
    /// conversation or a newer request wants another configuration, in which case it leaves the
    /// thread to them and returns.
    func prepare(for configuration: LocalAgentConversationConfiguration) async throws {
        try await prepare(
            for: configuration,
            deadline: Date().addingTimeInterval(configuration.timeout),
            opening: false)
    }

    private func prepare(
        for configuration: LocalAgentConversationConfiguration,
        deadline: Date,
        opening: Bool
    ) async throws {
        let preparedServer = try await prepareServer(
            for: configuration,
            deadline: deadline)
        try await prepareThread(
            for: configuration,
            server: preparedServer,
            deadline: deadline,
            opening: opening)
    }

    private func prepareServer(
        for configuration: LocalAgentConversationConfiguration,
        deadline: Date
    ) async throws -> CodexAppServer {
        guard configuration.provider == .codexCLI else {
            preconditionFailure("CodexAppServerRuntime received \(configuration.provider)")
        }
        let requested = LaunchIdentity(
            executable: configuration.executable,
            workDirectory: configuration.workDirectory,
            supportedFeatures: supportedFeatures)
        if let identity, identity != requested {
            throw Self.error("a session-scoped Codex app-server cannot change its launch identity")
        }
        identity = requested
        if let server, server.isRunning {
            return server
        }
        server = nil
        preparedThread = nil
        preparingThread = nil
        activeThreadID = nil
        if preparingServer == nil {
            let lifetime = self.lifetime
            let runtimeBaseDirectory = self.runtimeBaseDirectory
            preparingServer = ServerPreparation(
                id: UUID(),
                task: Task.detached(priority: .utility) {
                    try await CodexAppServer.start(
                        identity: requested,
                        runtimeBaseDirectory: runtimeBaseDirectory,
                        deadline: deadline,
                        lifetime: lifetime)
                })
        }
        guard let preparation = preparingServer else {
            throw Self.error("Codex app-server preparation was unavailable")
        }
        do {
            let preparedServer = try await awaitServerPreparation(preparation)
            if preparingServer?.id == preparation.id {
                server = preparedServer
                preparingServer = nil
            }
            return preparedServer
        } catch {
            if preparingServer?.id == preparation.id {
                preparingServer = nil
            }
            throw error
        }
    }

    /// `opening` marks an attempt's open, which must end with a thread for its own configuration
    /// and so may always replace one prepared for another. A prewarm may replace one only while it
    /// is the newest request and no attempt is opening; otherwise it returns and leaves the thread
    /// to whoever asked for it. Without that rule a prewarm and an open could trade evictions: each
    /// resumed from a preparation the other had already installed, each finding the other's thread
    /// stale, one thread/unsubscribe plus thread/start per round until the open happened to be
    /// resumed first. CI saw it as request counts exactly doubled.
    private func prepareThread(
        for configuration: LocalAgentConversationConfiguration,
        server: CodexAppServer,
        deadline: Date,
        opening: Bool
    ) async throws {
        latestThreadRequest += 1
        let request = latestThreadRequest
        while true {
            guard activeThreadID == nil else { return }
            let mayReplace = opening
                || (request == latestThreadRequest && openingConversations == 0)
            if let preparedThread {
                if preparedThread.configuration == configuration || !mayReplace { return }
            }

            if let preparation = preparingThread {
                if preparation.configuration != configuration && !mayReplace { return }
                do {
                    let thread = try await awaitThreadPreparation(preparation)
                    // Background prewarm and the first attempt may await the same task. Only the
                    // first resumed waiter may install it.
                    if preparingThread?.id == preparation.id {
                        preparedThread = thread
                        preparingThread = nil
                    }
                } catch {
                    if preparingThread?.id == preparation.id {
                        preparingThread = nil
                    }
                    invalidate(server)
                    throw error
                }
                continue
            }

            let staleThread = preparedThread
            preparedThread = nil
            let cleanupRequestID = staleThread.map { _ in takeRequestID() }
            let startRequestID = takeRequestID()
            let supportedFeatures = self.supportedFeatures
            preparingThread = ThreadPreparation(
                id: UUID(),
                configuration: configuration,
                task: Task.detached(priority: .utility) {
                    if let staleThread, let cleanupRequestID {
                        try await Self.unsubscribe(
                            threadID: staleThread.id,
                            server: server,
                            requestID: cleanupRequestID,
                            deadline: deadline)
                    }
                    return try await Self.startThread(
                        for: configuration,
                        server: server,
                        requestID: startRequestID,
                        supportedFeatures: supportedFeatures,
                        deadline: deadline)
                })
        }
    }

    func openConversation(
        for configuration: LocalAgentConversationConfiguration,
        deadline: Date
    )
        async throws -> any LocalAgentConversation {
        openingConversations += 1
        defer { openingConversations -= 1 }
        try await prepare(for: configuration, deadline: deadline, opening: true)
        guard let server, server.isRunning else {
            throw Self.error("Codex app-server was not ready")
        }
        guard activeThreadID == nil else {
            throw Self.error("Codex app-server already has an active coaching conversation")
        }
        guard let thread = preparedThread, thread.configuration == configuration else {
            invalidate(server)
            throw Self.error("Codex target thread was not ready")
        }
        preparedThread = nil
        activeThreadID = thread.id
        return CodexAppServerConversation(
            runtime: self,
            threadID: thread.id,
            configuration: configuration)
    }

    nonisolated func terminateNow() {
        lifetime.terminateAll()
    }

    private func awaitServerPreparation(
        _ preparation: ServerPreparation
    ) async throws -> CodexAppServer {
        let lifetime = self.lifetime
        return try await withTaskCancellationHandler {
            try await preparation.task.value
        } onCancel: {
            preparation.task.cancel()
            lifetime.terminateAll()
        }
    }

    private func awaitThreadPreparation(
        _ preparation: ThreadPreparation
    ) async throws -> PreparedThread {
        let lifetime = self.lifetime
        return try await withTaskCancellationHandler {
            try await preparation.task.value
        } onCancel: {
            preparation.task.cancel()
            lifetime.terminateAll()
        }
    }

    private static func startThread(
        for configuration: LocalAgentConversationConfiguration,
        server: CodexAppServer,
        requestID: Int,
        supportedFeatures: Set<String>,
        deadline: Date
    ) async throws -> PreparedThread {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var config: [String: Any] = [
            "mcp_servers": [:],
            "project_root_markers": [],
            "project_doc_max_bytes": 0,
            "model_reasoning_effort":
                CLIBrainClient.codexEffort(configuration.reasoningEffort),
        ]
        // `--disable <name>` is documented as equivalent to `-c features.<name>=false`, and
        // openai/codex#21952 reports the launch flag not reaching the app-server's tool builder.
        // Deliver the same disable set through the per-thread config override as well, so the
        // deny-list `codex exec` coaching relied on is not silently inert here.
        let disabledFeatures = disabledFeatures(advertised: supportedFeatures)
        if !disabledFeatures.isEmpty {
            config["features"] = disabledFeatures
        }
        var parameters: [String: Any] = [
            "cwd": configuration.workDirectory.path,
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "ephemeral": true,
            "baseInstructions": JarvisPrompts.LocalAgent.codexDirectResponse
                + "\n\n" + configuration.instructions,
            "config": config,
        ]
        if !configuration.model.isEmpty {
            parameters["model"] = configuration.model
        }
        try await server.send(
            method: "thread/start",
            parameters: parameters,
            id: requestID,
            timeout: try remainingTimeout(until: deadline))
        let result = try await waitForResponse(
            id: requestID,
            server: server,
            deadline: deadline)
        guard let thread = result["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            throw error("Codex thread/start returned no thread")
        }
        let instructionSources = result["instructionSources"] as? [Any] ?? []
        guard thread["ephemeral"] as? Bool == true,
              thread["path"] == nil || thread["path"] is NSNull,
              instructionSources.isEmpty else {
            throw error(
                "Codex returned a non-ephemeral or instruction-loaded thread: "
                + jsonDescription(result))
        }
        let readyMs = Int(
            (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
        jlog("Jarvis: Codex target thread ready in \(readyMs)ms")
        return PreparedThread(id: threadID, configuration: configuration)
    }

    private static func unsubscribe(
        threadID: String,
        server: CodexAppServer,
        requestID: Int,
        deadline: Date? = nil
    ) async throws {
        let cleanupDeadline = min(
            deadline ?? .distantFuture,
            Date().addingTimeInterval(threadCleanupTimeout))
        try await server.send(
            method: "thread/unsubscribe",
            parameters: ["threadId": threadID],
            id: requestID,
            timeout: try remainingTimeout(until: cleanupDeadline))
        _ = try await waitForResponse(
            id: requestID,
            server: server,
            deadline: cleanupDeadline)
    }

    fileprivate func respond(
        threadID: String,
        configuration: LocalAgentConversationConfiguration,
        turn: LocalAgentTurn,
        onRequestDispatched: @Sendable () -> Void
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
                timeout: try Self.remainingTimeout(until: deadline))
            onRequestDispatched()

            var firstAssistantAt: UInt64?
            var completedText: String?
            var fragments: [String] = []
            var turnID: String?
            while true {
                guard let line = try await server.nextLineBefore(deadline: deadline) else {
                    guard let turnID else {
                        throw Self.timeoutError(
                            "Codex turn timed out before turn/start returned an id")
                    }
                    try await interruptTimedOutTurn(
                        threadID: threadID,
                        turnID: turnID,
                        server: server)
                    throw RecoveredTurnTimeout(seconds: turn.timeout)
                }
                guard let payload = Self.object(from: line.text) else { continue }
                if payload["id"] as? Int == requestID {
                    if let rpcError = payload["error"] {
                        throw Self.error(
                            "Codex turn/start failed: \(Self.jsonDescription(rpcError))")
                    }
                    if let result = payload["result"] as? [String: Any] {
                        turnID = Self.turnID(in: result) ?? turnID
                    }
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
                turnID = Self.turnID(in: parameters) ?? turnID

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
        } catch let error as RecoveredTurnTimeout {
            throw error
        } catch {
            invalidate(server)
            throw error
        }
    }

    /// Recover a workload timeout at the narrowest provider scope. The server is reusable only after
    /// both the interrupt RPC and the matching terminal turn notification are observed; otherwise
    /// the caller invalidates it because the shared stream's state is uncertain.
    private func interruptTimedOutTurn(
        threadID: String,
        turnID: String,
        server: CodexAppServer
    ) async throws {
        let requestID = takeRequestID()
        let deadline = Date().addingTimeInterval(Self.threadCleanupTimeout)
        try await server.send(
            method: "turn/interrupt",
            parameters: [
                "threadId": threadID,
                "turnId": turnID,
            ],
            id: requestID,
            timeout: try Self.remainingTimeout(until: deadline))

        var acknowledged = false
        var terminal = false
        while !acknowledged || !terminal {
            let line = try await server.nextLine(deadline: deadline)
            guard let payload = Self.object(from: line.text) else { continue }
            if Self.isServerRequest(payload) {
                throw Self.error(
                    "Codex emitted an unexpected server request while interrupting a turn")
            }
            if payload["id"] as? Int == requestID {
                if let rpcError = payload["error"] {
                    throw Self.error(
                        "Codex turn/interrupt failed: \(Self.jsonDescription(rpcError))")
                }
                acknowledged = true
                continue
            }

            let method = payload["method"] as? String
            let parameters = payload["params"] as? [String: Any]
            if let notificationThread = parameters?["threadId"] as? String,
               notificationThread != threadID {
                continue
            }
            if Self.isDisallowedItemEvent(method: method, parameters: parameters) {
                throw Self.error(
                    "Codex emitted a disallowed item event while interrupting a turn")
            }
            guard method == "turn/completed",
                  Self.turnID(in: parameters) == turnID,
                  let completedTurn = parameters?["turn"] as? [String: Any],
                  let status = completedTurn["status"] as? String,
                  Self.terminalTurnStatuses.contains(status) else {
                continue
            }
            terminal = true
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
            try await Self.unsubscribe(
                threadID: threadID,
                server: server,
                requestID: requestID)
        } catch {
            jlog("Jarvis: Codex thread unsubscribe failed: \(error.localizedDescription)")
            invalidate(server)
        }
    }

    private static func waitForResponse(
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
        preparingThread?.task.cancel()
        server.finish()
        self.server = nil
        preparedThread = nil
        preparingThread = nil
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

    private static func turnID(in object: [String: Any]?) -> String? {
        if let turnID = object?["turnId"] as? String {
            return turnID
        }
        return (object?["turn"] as? [String: Any])?["id"] as? String
    }

    /// The agentic feature names to switch off, intersected with what this installation advertises
    /// so a renamed or absent name is never passed. Shared by the launch argv and the per-thread
    /// config override, which are the two delivery paths for the same `features.<name>=false` knob.
    static func disabledFeatures(advertised: Set<String>) -> [String: Bool] {
        var disabled: [String: Bool] = [:]
        for feature in CLIBrainClient.codexDisabledAgentFeatures where advertised.contains(feature) {
            disabled[feature] = false
        }
        return disabled
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

    fileprivate static func timeoutError(_ detail: String) -> NSError {
        NSError(
            domain: "CodexAppServerRuntime",
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: detail])
    }

    fileprivate static func remainingTimeout(until deadline: Date) throws -> TimeInterval {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining >= 0.01 else {
            throw timeoutError("Codex app-server request timed out")
        }
        return remaining
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

    func respond(
        to turn: LocalAgentTurn,
        onRequestDispatched: @Sendable () -> Void
    ) async throws -> LocalAgentTurnResult {
        try await runtime.respond(
            threadID: threadID,
            configuration: configuration,
            turn: turn,
            onRequestDispatched: onRequestDispatched)
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
                      deadline: Date,
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
        ]
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
                timeout: try CodexAppServerRuntime.remainingTimeout(until: deadline))
            while true {
                let line = try await server.nextLine(deadline: deadline)
                guard let payload = try? JSONSerialization.jsonObject(
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
                timeout: try CodexAppServerRuntime.remainingTimeout(until: deadline))
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
        let remaining = try CodexAppServerRuntime.remainingTimeout(until: deadline)
        return try await process.nextLine(timeout: remaining)
    }

    /// A turn deadline is recoverable at thread scope, so observing it must not kill the shared
    /// process. Callers either synchronize with `turn/interrupt` or invalidate the server themselves.
    func nextLineBefore(deadline: Date) async throws -> AgentRuntimeProcess.Line? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining >= 0.01 else { return nil }
        return try await process.nextLineOrNil(timeout: remaining)
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
