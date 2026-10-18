import Foundation
import JarvisCore

@MainActor
final class ReferenceLibrary {
    private struct Metadata: Decodable {
        let generation: Int
        let state: String
        let total_count: Int
    }
    private struct Admission: Decodable { let state: String; let catalog: DocumentCatalog? }
    private enum Ownership { case pending(UUID), active(UUID) }

    let appInstanceID: UUID
    private let supervisor: ReferenceHelperSupervisor
    private var stopped = false
    private var generation = 0
    private var enabled = false
    private var disabledTools: Set<String> = []
    private var sources: [ReferenceSource] = []
    private var metadata: ReferenceAdmission.Metadata?
    private var owned: [UUID: Ownership] = [:]
    private var pending: [UUID: UUID] = [:]
    private var ended: [UUID: UUID] = [:]
    private var admitted: [UUID: ReferenceAdmissionResult.Admitted] = [:]
    private var connection: Task<Void, Error>?
    private var connectedID: UUID?
    private var connectionFailed = false
    private var restartAvailable = true
    private var hasConnected = false
    private var configuredGeneration: Int?

    init(supervisor: ReferenceHelperSupervisor, appInstanceID: UUID = UUID()) {
        self.supervisor = supervisor; self.appInstanceID = appInstanceID
    }

    func shutdown() {
        stopped = true
        connection?.cancel()
    }

    func prepare(enabled: Bool, sources: [ReferenceSource], disabledTools: Set<String> = []) {
        guard !stopped else { return }
        self.disabledTools = disabledTools
        let configured = updateConfiguration(enabled: enabled, sources: sources)
        Task { try? await sendConfiguration(configured, enabled: enabled, sources: sources) }
    }

    func configure(enabled: Bool, sources: [ReferenceSource], disabledTools: Set<String> = []) async throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        self.disabledTools = disabledTools
        let configured = updateConfiguration(enabled: enabled, sources: sources)
        try await sendConfiguration(configured, enabled: enabled, sources: sources)
    }

    private func updateConfiguration(enabled: Bool, sources: [ReferenceSource]) -> Int {
        generation += 1
        self.enabled = enabled; self.sources = sources
        metadata = .preparing(generation: generation)
        return generation
    }

    private func sendConfiguration(_ configured: Int, enabled: Bool, sources: [ReferenceSource]) async throws {
        do {
            try await connect()
            try Task.checkCancellation()
            if generation != configured || configuredGeneration == configured { return }
            let data = try await supervisor.request("configure", payload: configuration(generation: configured, enabled: enabled, sources: sources))
            let reply = try JSONDecoder().decode(Metadata.self, from: data)
            if generation == configured { configuredGeneration = configured; update(reply) }
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            if generation == configured { metadata = .failed(generation: configured) }
            throw error
        }
    }

    func admit(startID: UUID, deadline: ContinuousClock.Instant = .now + .seconds(2)) async throws -> ReferenceAdmissionResult {
        guard !owned.values.contains(where: { ownership in
            switch ownership { case .pending(let id), .active(let id): id == startID }
        }) else { throw ReferenceAccessFailure(reason: .duplicateStart) }
        restartAvailable = true
        connectionFailed = false
        let started = ContinuousClock.now
        let policy = ReferenceAdmission(startedAt: .zero, budget: started.duration(to: deadline))
        var sessionID = UUID()
        pending[startID] = sessionID
        owned[sessionID] = .pending(startID)
        beginConnection()
        do {
            while true {
                try Task.checkCancellation()
                guard pending[startID] == sessionID else { throw CancellationError() }
                switch policy.decide(now: started.duration(to: .now), enabled: enabled, generation: generation, metadata: metadata) {
                case .omit(let reason):
                    abandonNow(startID: startID)
                    return .omitted(startID: startID, reason: reason)
                case .wait:
                    if connectionFailed { throw ReferenceAccessFailure(reason: .unavailable) }
                    if connectedID == supervisor.connectionID, supervisor.isRunning {
                        let requested = generation
                        let data = try await supervisor.request("metadata", payload: encode(["app_instance_id": appInstanceID.uuidString, "generation": requested]), timeout: remaining(deadline))
                        if generation == requested { update(try JSONDecoder().decode(Metadata.self, from: data)) }
                    }
                    try await Task.sleep(for: min(.milliseconds(25), remaining(deadline)))
                case .admit(let requested):
                    if connectionFailed { throw ReferenceAccessFailure(reason: .unavailable) }
                    guard connectedID == supervisor.connectionID, supervisor.isRunning else {
                        beginConnection()
                        try await Task.sleep(for: min(.milliseconds(25), remaining(deadline)))
                        continue
                    }
                    let data = try await supervisor.request("admit", session: sessionID,
                        payload: encode(["app_instance_id": appInstanceID.uuidString, "start_id": startID.uuidString, "generation": requested]),
                        timeout: remaining(deadline))
                    try Task.checkCancellation()
                    guard pending[startID] == sessionID else { throw CancellationError() }
                    let reply = try JSONDecoder().decode(Admission.self, from: data)
                    if generation != requested {
                        end(sessionID: sessionID, startID: startID)
                        sessionID = UUID(); pending[startID] = sessionID; owned[sessionID] = .pending(startID)
                        continue
                    }
                    guard ContinuousClock.now < deadline else { throw ReferenceHelperSupervisor.Failure.timeout }
                    switch reply.state {
                    case "ready":
                        guard let catalog = reply.catalog else { throw ReferenceProtocolError.malformed }
                        let context = try SessionContext(documentCatalog: catalog)
                        let result = ReferenceAdmissionResult.Admitted(startID: startID, sessionID: sessionID,
                            session: HelperDocumentSession(sessionID: sessionID, library: self), context: context,
                            accessPolicy: .init(disabledTools: disabledTools))
                        admitted[startID] = result
                        return .admitted(result)
                    case "preparing", "superseded": metadata = nil
                    case "empty", "disabled":
                        abandonNow(startID: startID)
                        return .omitted(startID: startID, reason: reply.state == "empty" ? .empty : .disabled)
                    default: throw ReferenceAccessFailure(reason: .unavailable)
                    }
                }
            }
        } catch {
            abandonNow(startID: startID)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let timedOut = ContinuousClock.now >= deadline || (error as? ReferenceHelperSupervisor.Failure) == .timeout
            return .omitted(startID: startID, reason: timedOut ? .timeout : .failed)
        }
    }

    @discardableResult
    func accept(startID: UUID) throws -> ReferenceAdmissionResult.Admitted {
        guard let result = admitted.removeValue(forKey: startID), pending.removeValue(forKey: startID) == result.sessionID else {
            throw ReferenceAccessFailure(reason: .abandonedStart)
        }
        owned[result.sessionID] = .active(startID)
        return result
    }

    func abandon(startID: UUID) { abandonNow(startID: startID) }

    func release(sessionID: UUID) {
        guard let ownership = owned[sessionID] else { return }
        switch ownership {
        case .pending(let start), .active(let start):
            if pending[start] == sessionID { pending.removeValue(forKey: start); admitted.removeValue(forKey: start) }
            end(sessionID: sessionID, startID: start)
        }
    }

    func reconnect() async throws {
        connectedID = nil
        try await connect()
    }

    func request(_ operation: String, sessionID: UUID, payload: [String: Any]) async throws -> Data {
        do {
            guard owned[sessionID] != nil else { throw ReferenceAccessFailure(reason: .released) }
            try await connect()
            try Task.checkCancellation()
            guard owned[sessionID] != nil else { throw ReferenceAccessFailure(reason: .released) }
            var payload = payload
            payload["app_instance_id"] = appInstanceID.uuidString
            let timeout: Duration = operation == "search" ? .seconds(3) : .seconds(2)
            let data = try await supervisor.request(operation, session: sessionID, payload: encode(payload), timeout: timeout)
            try Task.checkCancellation()
            guard owned[sessionID] != nil else { throw ReferenceAccessFailure(reason: .released) }
            struct Status: Decodable { let status: String? }
            if let status = try JSONDecoder().decode(Status.self, from: data).status, status != "ok", status != "partial" {
                guard let reason = ReferenceAccessFailure.Reason(rawValue: status) else { throw ReferenceProtocolError.malformed }
                throw ReferenceAccessFailure(reason: reason)
            }
            return data
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let failure = error as? ReferenceAccessFailure { throw failure }
            throw ReferenceAccessFailure(reason: .unavailable)
        }
    }

    private func abandonNow(startID: UUID) {
        admitted.removeValue(forKey: startID)
        if let sessionID = pending.removeValue(forKey: startID) { end(sessionID: sessionID, startID: startID) }
    }

    private func end(sessionID: UUID, startID: UUID) {
        owned.removeValue(forKey: sessionID)
        ended[sessionID] = startID
        Task {
            guard supervisor.isRunning else { return }
            do {
                _ = try await supervisor.request("release", session: sessionID,
                    payload: encode(["app_instance_id": appInstanceID.uuidString, "start_id": startID.uuidString]), timeout: .milliseconds(500))
                ended.removeValue(forKey: sessionID)
            } catch {
                // Reconciliation retries ownership cleanup after an uncertain release.
            }
        }
    }

    private func beginConnection() {
        guard !stopped, connection == nil, connectedID != supervisor.connectionID || !supervisor.isRunning else { return }
        guard restartAvailable else { connectionFailed = true; return }
        if hasConnected { restartAvailable = false }
        connection = Task {
            defer { connection = nil }
            do {
                try Task.checkCancellation()
                try await supervisor.start()
                let reconciledEnds = Set(ended.keys)
                _ = try await supervisor.request("reconcile", payload: encode([
                    "app_instance_id": appInstanceID.uuidString,
                    "owned_session_ids": owned.keys.map { $0.uuidString }.sorted(),
                ]))
                for id in reconciledEnds { ended.removeValue(forKey: id) }
                if generation > 0 {
                    let configured = generation
                    let reply = try await supervisor.request("configure", payload: configuration(generation: configured, enabled: enabled, sources: sources))
                    if configured == generation { configuredGeneration = configured }
                    update(try JSONDecoder().decode(Metadata.self, from: reply))
                }
                connectedID = supervisor.connectionID
                hasConnected = true
                connectionFailed = false
            } catch {
                connectedID = nil; configuredGeneration = nil; connectionFailed = true
                throw error
            }
        }
    }

    private func connect() async throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        beginConnection()
        if let connection { try await connection.value }
        guard connectedID == supervisor.connectionID, supervisor.isRunning else { throw ReferenceAccessFailure(reason: .unavailable) }
    }

    private func update(_ reply: Metadata) {
        guard reply.generation == generation else { return }
        guard reply.total_count >= 0 else { metadata = .failed(generation: generation); return }
        switch reply.state {
        case "ready": metadata = .ready(generation: reply.generation, count: reply.total_count)
        case "failed": metadata = .failed(generation: reply.generation)
        case "preparing", "disabled": metadata = .preparing(generation: reply.generation)
        default: metadata = .failed(generation: reply.generation)
        }
    }

    private func configuration(generation: Int, enabled: Bool, sources: [ReferenceSource]) throws -> Data {
        try encode(["app_instance_id": appInstanceID.uuidString, "generation": generation, "enabled": enabled,
                    "sources": sources.map { ["source_id": $0.id.uuidString, "path": $0.url.path] }])
    }
    private func encode(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func remaining(_ deadline: ContinuousClock.Instant) -> Duration { max(.zero, ContinuousClock.now.duration(to: deadline)) }
}
