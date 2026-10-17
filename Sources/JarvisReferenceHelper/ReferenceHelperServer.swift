import Foundation
import JarvisCore
import SQLite3

actor ReferenceHelperServer {
    private let store: ReferenceDocumentStore
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var seen: Set<UUID> = []

    init(store: ReferenceDocumentStore) { self.store = store }

    static func receive() throws -> Data? {
        func exact(_ count: Int, allowEOF: Bool = false) throws -> Data? {
            var result = Data()
            while result.count < count {
                let piece = try FileHandle.standardInput.read(upToCount: count - result.count) ?? Data()
                if piece.isEmpty {
                    if allowEOF && result.isEmpty { return nil }
                    throw ReferenceProtocolError.truncated
                }
                result.append(piece)
            }
            return result
        }
        guard let header = try exact(4, allowEOF: true) else { return nil }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= ReferenceFrame.maximumBytes else { throw ReferenceProtocolError.oversized }
        return try exact(length)
    }

    static func send(id: UUID, status: String = "ok", result: Data = Data("{}".utf8)) throws {
        let object: [String: Any] = ["protocol": 1, "id": id.uuidString.lowercased(), "status": status,
                                     "result": try JSONSerialization.jsonObject(with: result)]
        try FileHandle.standardOutput.write(contentsOf: ReferenceFrame.encode(JSONSerialization.data(withJSONObject: object)))
    }

    static func hello() throws -> Data {
        let environment = ProcessInfo.processInfo.environment
        let secretPresent = ["OPENAI_API_KEY", "GEMINI_API_KEY", "ANTHROPIC_API_KEY"].contains { environment[$0] != nil }
            || environment.keys.contains {
                let key = $0.uppercased()
                return key.hasPrefix("DYLD_") || key.hasPrefix("PYTHON") || key.hasSuffix("_PROXY")
            }
        return try JSONSerialization.data(withJSONObject: [
            "protocol": 1, "engine": "sqlite-fts5", "sqlite": String(cString: sqlite3_libversion()),
            "isolated": !secretPresent, "secret_present": secretPresent, "pid": ProcessInfo.processInfo.processIdentifier,
        ])
    }

    func run() async throws {
        let (frames, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        let reader = Task.detached {
            do {
                while let frame = try Self.receive() {
                    if case .dropped = continuation.yield(frame) { throw ReferenceProtocolError.oversized }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        defer {
            reader.cancel()
            for task in tasks.values { task.cancel() }
        }
        for try await frame in frames {
            let request = try ReferenceHelperRequest(frame)
            guard seen.insert(request.id).inserted, seen.count <= 100_000 else { throw ReferenceProtocolError.malformed }
            switch request.operation {
            case "hello": try Self.send(id: request.id, result: Self.hello())
            case "shutdown":
                for (id, task) in tasks {
                    task.cancel()
                    try Self.send(id: id, status: "cancelled")
                }
                tasks.removeAll()
                await store.close()
                try Self.send(id: request.id)
                return
            case "cancel":
                let payload = try JSONDecoder().decode(Cancel.self, from: request.payload)
                if let target = payload.request_id, let task = tasks.removeValue(forKey: target) {
                    task.cancel()
                    try Self.send(id: target, status: "cancelled")
                }
                try Self.send(id: request.id)
            default:
                guard tasks.count < 32 else {
                    try Self.send(id: request.id, status: "unavailable")
                    continue
                }
                tasks[request.id] = Task {
                    let result: Data
                    let status: String
                    do {
                        result = try await store.execute(request)
                        status = "ok"
                    } catch {
                        result = Data("{}".utf8)
                        status = "unavailable"
                    }
                    guard !Task.isCancelled else { return }
                    tasks.removeValue(forKey: request.id)
                    do { try Self.send(id: request.id, status: status, result: result) }
                    catch { exit(2) }
                }
            }
        }
        await store.close()
    }

    private struct Cancel: Decodable { let request_id: UUID? }
}
