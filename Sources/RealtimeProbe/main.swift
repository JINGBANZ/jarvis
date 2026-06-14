import Foundation
import JarvisCore

// Headless probe for the OpenAI GA Realtime transcription handshake. Uses the exact same
// RealtimeSession contract (connect URL + session.update) as the app, so a PASS here means the
// app's transcription session will negotiate. Needs only OPENAI_API_KEY — no mic, screen, or GUI.
//
//   OPENAI_API_KEY=sk-... swift run RealtimeProbe [model]
//
// Exits 0 on a successful session handshake, 1 on error/timeout.

let model = CommandLine.arguments.dropFirst().first ?? "gpt-4o-transcribe"

guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
    FileHandle.standardError.write(Data("ERROR: set OPENAI_API_KEY in the environment.\n".utf8))
    exit(2)
}

print("→ connecting: \(RealtimeSession.connectURL().absoluteString)")
print("→ model: \(model)")

final class Probe: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let key: String
    let model: String
    var task: URLSessionWebSocketTask?
    let done = DispatchSemaphore(value: 0)
    var success = false

    init(key: String, model: String) { self.key = key; self.model = model }

    func run(timeout: TimeInterval) {
        var req = URLRequest(url: RealtimeSession.connectURL())
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: req)
        task?.resume()
        // session.update selects a transcription session + configures VAD/model.
        send(RealtimeSession.sessionUpdate(model: model))
        receive()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            print("✗ TIMEOUT — no session.created/updated within \(Int(timeout))s")
        }
        task?.cancel(with: .goingAway, reason: nil)
    }

    func send(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { if let e = $0 { print("  send error: \(e)") } }
    }

    func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                print("✗ socket failure: \(e.localizedDescription)")
                self.done.signal()
            case .success(let msg):
                if case .string(let text) = msg { self.handle(text) }
                self.receive()
            }
        }
    }

    func handle(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "session.created", "session.updated", "transcription_session.created", "transcription_session.updated":
            print("✓ \(type)")
            success = true
            done.signal()
        case "error":
            print("✗ error event: \(text)")
            done.signal()
        default:
            print("  · \(type)")
        }
    }
}

let probe = Probe(key: key, model: model)
probe.run(timeout: 12)
print(probe.success ? "\nPASS — transcription session negotiated." : "\nFAIL — see above.")
exit(probe.success ? 0 : 1)
