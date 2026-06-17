import Foundation

/// Reads, lists, and deletes past dev-session directories so the activity viewer can browse history.
/// Foundation-only and stateless beyond its two URLs. All operations are bounded to immediate
/// subdirectories of `base` whose name matches the session-id shape, so a stray `--log-dir` or a
/// malformed persisted filename can't make it touch anything outside the log tree. See
/// wiki/build-and-run.md.
public struct SessionStore: Sendable {
    public struct Session: Sendable, Equatable {
        public let id: String        // directory name, e.g. "2026-06-16_10-00-00_aaaa"
        public let label: String     // human label, e.g. "2026-06-16 10:00:00"
        public let url: URL
        public let isCurrent: Bool
    }

    private let base: URL
    private let current: URL?

    public init(base: URL, current: URL?) {
        self.base = base
        self.current = current
    }

    /// `yyyy-MM-dd_HH-mm-ss_xxxx` (timestamp + 4-char suffix; see AppDelegate.newSessionID). The
    /// regex is built locally (not a stored static) to stay Sendable-clean under Swift 6.
    private static func isSessionID(_ s: String) -> Bool {
        s.wholeMatch(of: /^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_[0-9A-Za-z]{4}$/) != nil
    }
    /// A bare `shot-N.jpg` filename — anything with slashes or `..` is rejected (path-traversal guard).
    private static func isShotName(_ s: String) -> Bool {
        s.wholeMatch(of: /^shot-[0-9]+\.jpg$/) != nil
    }

    private struct Line: Decodable { let t: String; let m: String; let s: String? }

    /// Immediate subdirectories of `base` that look like a session and hold a `jarvis-activity.jsonl`,
    /// newest-first. The live session always appears (its `.jsonl` is created on `enable`).
    public func listSessions() -> [Session] {
        let curPath = current?.standardizedFileURL.path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names
            .filter { Self.isSessionID($0) }
            .filter { FileManager.default.fileExists(atPath:
                base.appendingPathComponent($0).appendingPathComponent("jarvis-activity.jsonl").path) }
            .sorted(by: >)   // id is a lexically-sortable timestamp ⇒ newest first
            .map { name in
                let url = base.appendingPathComponent(name)
                return Session(id: name, label: Self.label(from: name), url: url,
                               isCurrent: curPath != nil && url.standardizedFileURL.path == curPath)
            }
    }

    /// Decode a session's `.jsonl` into entries paired with their screenshot bytes (when the `s`
    /// filename is a valid, present `shot-N.jpg`). Malformed lines are skipped; an invalid or missing
    /// shot degrades to a text-only row (`nil` bytes).
    public func entries(for session: Session) -> [(ActivityLog.Entry, Data?)] {
        let url = session.url.appendingPathComponent("jarvis-activity.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [(ActivityLog.Entry, Data?)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw.utf8)) else { continue }
            var bytes: Data?
            var shotName: String?
            if let s = line.s, Self.isShotName(s) {
                shotName = s
                bytes = try? Data(contentsOf: session.url.appendingPathComponent(s))
            }
            out.append((ActivityLog.Entry(time: line.t, message: line.m,
                                          imageFile: bytes == nil ? nil : shotName), bytes))
        }
        return out
    }

    /// Delete every past session directory (immediate, session-shaped subdir of `base`), sparing the
    /// current session and skipping symlinks. Never removes `base` itself or anything outside it.
    public func clearHistory() {
        let curPath = current?.standardizedFileURL.path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for name in names where Self.isSessionID(name) {
            let url = base.appendingPathComponent(name)
            if url.standardizedFileURL.path == curPath { continue }                 // spare current
            let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if vals?.isSymbolicLink == true { continue }                            // don't follow symlinks
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// "2026-06-16_10-00-00_aaaa" → "2026-06-16 10:00:00".
    private static func label(from id: String) -> String {
        let parts = id.split(separator: "_")
        guard parts.count >= 2 else { return id }
        return "\(parts[0]) \(parts[1].replacingOccurrences(of: "-", with: ":"))"
    }
}
