import Foundation

/// Per-session wire-level record of every brain (LLM provider) round trip — the exact request body
/// the harness sent and the exact response body it got back, as `brain-traffic.jsonl` in the session
/// directory. This is the raw material for the one-click session evaluation (`SessionEvaluator`):
/// judging our context engineering needs the *actual* bytes on the wire (instructions, message order,
/// tool schemas, usage/cached-token counts), not a paraphrase — and having it locally replaces
/// pulling the same data by hand from the OpenAI dashboard logs.
///
/// Mirrors `ActivityLog`'s lifecycle: `.shared`, enabled per session via `enable(directory:)`,
/// no-op until then. Base64 screenshot payloads are redacted before persisting (the pixels already
/// live in the session dir as `shot-N.jpg`), so the file stays reviewable and owner-only text.
///
/// `@unchecked Sendable`: all mutable state is confined to the serial `queue`.
public final class BrainTrafficLog: @unchecked Sendable {
    public static let shared = BrainTrafficLog()
    public static let filename = "brain-traffic.jsonl"

    /// On-disk line: one round trip. `request`/`response` are the parsed JSON bodies (nested, not
    /// string-escaped) so the file is directly readable; a body that isn't valid JSON is kept as a
    /// string. `response` is nil when the transport threw (see `error`).
    /// Keys: t=time, tag=which client (coach/summarizer), ms=latency, status=HTTP status.
    private let queue = DispatchQueue(label: "jarvis.braintraffic")   // serializes state + disk writes
    private var dir: URL?         // nil ⇒ disabled (no disk writes)
    private let df: DateFormatter

    /// Internal so tests can spin up an isolated instance; the app uses `.shared`.
    init() {
        df = DateFormatter()
        // Fixed-format formatter: pin to en_US_POSIX + Gregorian so output is stable regardless of
        // the user's locale or system calendar (Apple QA1480) — same as ActivityLog.
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "HH:mm:ss"
    }

    /// Turn on recording for a session. An empty `brain-traffic.jsonl` is created at 0600 immediately,
    /// matching the session dir's owner-only posture.
    public func enable(directory: URL) {
        queue.sync {
            dir = directory
            let url = directory.appendingPathComponent(Self.filename)
            FileManager.default.createFile(atPath: url.path, contents: Data(),
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    /// Turn recording back off (no further disk writes).
    public func disable() {
        queue.sync { dir = nil }
    }

    /// Record one round trip. `response`/`status` are nil when the transport threw (then `error`
    /// carries why). Synchronous by design: the caller is already off the main thread (the brain's
    /// async request path), the redacted bodies are small, and a strict write order keeps the file an
    /// exact chronology of the session's calls.
    public func record(tag: String, request: Data, response: Data?, status: Int?,
                       latencyMs: Int, error: String? = nil, at date: Date = Date()) {
        queue.sync { [self] in
            guard let dir else { return }
            var line: [String: Any] = [
                "t": df.string(from: date),
                "tag": tag,
                "ms": latencyMs,
            ]
            line["status"] = status
            line["error"] = error
            line["request"] = Self.redactingImages(Self.jsonValue(request))
            if let response { line["response"] = Self.jsonValue(response) }
            guard let data = try? JSONSerialization.data(withJSONObject: line) else { return }
            append(data, in: dir)
        }
    }

    /// Parse a body into a JSON value for nesting; a non-JSON body degrades to its UTF-8 string.
    private static func jsonValue(_ data: Data) -> Any {
        (try? JSONSerialization.jsonObject(with: data)) ?? (String(data: data, encoding: .utf8) ?? "")
    }

    /// Recursively replace base64 `data:image/...` payloads with a short stub. The screenshot bytes
    /// are already persisted as `shot-N.jpg` by `ActivityLog`, so keeping them here would only bloat
    /// the traffic file (~100s of KB per call) without adding information.
    static func redactingImages(_ value: Any) -> Any {
        if let s = value as? String {
            guard s.hasPrefix("data:image/") else { return s }
            return "[base64 image omitted — \(s.count / 1024) KB; the pixels are saved as shot-N.jpg in this session directory]"
        }
        if let arr = value as? [Any] { return arr.map { redactingImages($0) } }
        if let dict = value as? [String: Any] { return dict.mapValues { redactingImages($0) } }
        return value
    }

    /// Append one JSON line. Best-effort, like ActivityLog: a failed write just loses that line.
    /// Must run on `queue`.
    private func append(_ data: Data, in dir: URL) {
        let url = dir.appendingPathComponent(Self.filename)
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
        try? fh.write(contentsOf: Data([0x0A]))   // newline
    }
}
