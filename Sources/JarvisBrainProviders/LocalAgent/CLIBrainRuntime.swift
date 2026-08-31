import Foundation
import JarvisCore

enum LocalAgentInput: Sendable {
    case text(String)
    case imageJPEG(base64: String)
}

struct LocalAgentTurn: Sendable {
    let input: [LocalAgentInput]
    let timeout: TimeInterval
}

struct LocalAgentTurnResult: Sendable {
    let reply: String
    let metadata: Data?
    let dispatchedAt: UInt64
    let firstAssistantAt: UInt64?
    let completedAt: UInt64
}

struct LocalAgentConversationConfiguration: Sendable, Equatable {
    let provider: BrainProvider
    let executable: URL
    let model: String
    let reasoningEffort: String
    let workDirectory: URL
    let instructions: String
    let timeout: TimeInterval
}

protocol LocalAgentConversation: Sendable {
    func respond(
        to turn: LocalAgentTurn,
        onRequestDispatched: @Sendable () -> Void
    ) async throws -> LocalAgentTurnResult
    func finish() async
}

/// How a local-agent turn reached its provider, named in the session audit's request record.
///
/// The transports do not share a usage schema — Claude's warm query carries the Anthropic envelope,
/// `codex exec` reports OpenAI-shaped totals under its own key names, and the app-server reports
/// none — so a reader of the audit needs the transport to know which shape, if any, to expect.
///
/// Public because the raw values are part of the persisted traffic-record schema: the sealed-session
/// parser in `JarvisEvaluation` keys its usage interpretation on them rather than duplicating the
/// strings.
public enum LocalAgentTransport: String, Sendable {
    case warmQuery = "warm-query"
    case appServer = "app-server"
    case oneShotExec = "one-shot-exec"
}

protocol LocalAgentRuntimeBackend: Sendable {
    var transport: LocalAgentTransport { get }
    func prepare(for configuration: LocalAgentConversationConfiguration) async throws
    func openConversation(
        for configuration: LocalAgentConversationConfiguration,
        deadline: Date
    )
        async throws -> any LocalAgentConversation
    func terminateNow()
}

/// Reference-counted ownership of one provider runtime.
///
/// Releasing the final client owner terminates every child process synchronously.
///
/// `@unchecked Sendable` is justified because `backend` is immutable after initialization and
/// `ownerLock` guards both mutable ownership fields, `ownerCount` and `isTerminated`. Backend
/// termination runs only after the lock atomically selects one caller to perform it.
public final class CLIBrainRuntime: @unchecked Sendable {
    /// One logical client owner of a shared provider runtime.
    ///
    /// `@unchecked Sendable` is justified because `lock` guards the optional runtime reference.
    /// Copies of a `CLIBrainClient` share this lease, so releasing a retired route target is
    /// idempotent even while an attempt still holds a client snapshot.
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var runtime: CLIBrainRuntime?

        fileprivate init(runtime: CLIBrainRuntime) {
            self.runtime = runtime
        }

        deinit {
            release()
        }

        func release() {
            lock.lock()
            let runtime = self.runtime
            self.runtime = nil
            lock.unlock()
            runtime?.releaseOwner()
        }
    }

    private let backend: any LocalAgentRuntimeBackend
    var transport: LocalAgentTransport { backend.transport }
    private let ownerLock = NSLock()
    private var ownerCount = 0
    private var isTerminated = false

    init(backend: any LocalAgentRuntimeBackend) {
        self.backend = backend
    }

    public convenience init(
        provider: BrainProvider,
        codexSupportedFeatures: Set<String> = []
    ) {
        self.init(
            provider: provider,
            codexRuntimeBaseDirectory: CodexRuntimeHome.defaultBaseDirectory,
            codexSupportedFeatures: codexSupportedFeatures)
    }

    init(
        provider: BrainProvider,
        codexRuntimeBaseDirectory: URL,
        codexSupportedFeatures: Set<String> = []
    ) {
        switch provider {
        case .claudeCode:
            backend = ClaudeCodeRuntime()
        case .codexCLI:
            backend = CodexAppServerRuntime(
                runtimeBaseDirectory: codexRuntimeBaseDirectory,
                supportedFeatures: codexSupportedFeatures)
        case .openAI:
            preconditionFailure("OpenAI does not use a local CLI runtime")
        }
    }

    deinit {
        terminateNow()
    }

    func acquireLease() -> Lease {
        ownerLock.lock()
        precondition(!isTerminated, "cannot acquire an owner for a terminated CLI runtime")
        ownerCount += 1
        ownerLock.unlock()
        return Lease(runtime: self)
    }

    func prepareInBackground(for configuration: LocalAgentConversationConfiguration) {
        let backend = self.backend
        Task.detached(priority: .utility) {
            do {
                try await backend.prepare(for: configuration)
            } catch is CancellationError {
                // Releasing a stopped or superseded session is intentionally quiet.
            } catch {
                jlog("Jarvis: \(configuration.provider.displayName) runtime prewarm failed: "
                     + error.localizedDescription)
            }
        }
    }

    func openConversation(
        for configuration: LocalAgentConversationConfiguration,
        deadline: Date
    )
        async throws -> any LocalAgentConversation {
        try await backend.openConversation(for: configuration, deadline: deadline)
    }

    func terminateNow() {
        ownerLock.lock()
        let shouldTerminate = !isTerminated
        isTerminated = true
        ownerLock.unlock()
        if shouldTerminate {
            backend.terminateNow()
        }
    }

    private func releaseOwner() {
        ownerLock.lock()
        precondition(ownerCount > 0, "CLI runtime owner count underflow")
        ownerCount -= 1
        let shouldTerminate = ownerCount == 0 && !isTerminated
        if shouldTerminate {
            isTerminated = true
        }
        ownerLock.unlock()
        if shouldTerminate {
            backend.terminateNow()
        }
    }
}
