import Foundation

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

protocol LocalAgentRuntimeBackend: Sendable {
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
