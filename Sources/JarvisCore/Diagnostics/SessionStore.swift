import Foundation

/// Every operation is bounded to immediate session-shaped subdirectories of `base`, so a malformed
/// persisted name can't touch anything outside the log tree.
public struct SessionStore: Sendable {
    public struct Session: Sendable, Equatable {
        public let id: String        // directory name, e.g. "2026-06-16_10-00-00_aaaa"
        public let label: String     // human label, e.g. "2026-06-16 10:00:00"
        public let url: URL
        public let isCurrent: Bool
        /// Nil means unknown (an older session or an unreadable marker), which shows no notice.
        public let evidenceIsComplete: Bool?
    }

    public struct EntrySnapshot: Sendable {
        public let entries: [(ActivityLog.Entry, Data?)]
        public let total: Int
    }

    private let base: URL
    private let current: URL?

    public init(base: URL, current: URL?) {
        self.base = base
        self.current = current
    }

    public static func baseDirectory(isDevelopmentBuild: Bool, bundleURL: URL,
                                     appDataDirectory: URL) -> URL {
        if isDevelopmentBuild {
            return bundleURL.deletingLastPathComponent().appendingPathComponent(".jarvis", isDirectory: true)
        }
        return appDataDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Includes contentless sessions, which `listSessions()` hides.
    public func newestSessionDirectory() -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.filter { Self.isSessionID($0) }
            .filter { name in
                (try? base.appendingPathComponent(name).resourceValues(forKeys: [.isDirectoryKey])
                    .isDirectory) == true
            }
            .sorted { Self.isNewer($0, than: $1) }.first.map { base.appendingPathComponent($0) }
    }

    private static func isSessionID(_ s: String) -> Bool {
        SessionDirectoryID(s) != nil
    }
    /// Path-traversal guard: anything with slashes or `..` is rejected.
    private static func isShotName(_ s: String) -> Bool {
        s.wholeMatch(of: /^shot-[0-9]+\.jpg$/) != nil
    }

    private struct Line: Decodable {
        let t: String
        let m: String
        let response: ActivityResponse?
        let s: String?
        /// Raw, so a kind this build doesn't know still decodes and goes through the classifier.
        let k: String?
        let o: TimeInterval?
        let q: UInt64?
        let r: TimeInterval?
    }

    private struct LoadedEntry: Sendable {
        let entry: ActivityLog.Entry
        let imageData: Data?
        let occurredAt: TimeInterval?
    }

    /// Newest first. Past sessions without coaching content are hidden; the current one never is.
    public func listSessions() -> [Session] {
        let curPath = current?.standardizedFileURL.path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names
            .filter { Self.isSessionID($0) }
            .filter { FileManager.default.fileExists(atPath:
                base.appendingPathComponent($0).appendingPathComponent("jarvis-activity.jsonl").path) }
            .map { name -> Session in
                let url = base.appendingPathComponent(name)
                let isCurrent = curPath != nil && url.standardizedFileURL.path == curPath
                return Session(
                    id: name,
                    label: Self.label(from: name),
                    url: url,
                    isCurrent: isCurrent,
                    evidenceIsComplete: Self.evidenceIsComplete(in: url))
            }
            .filter { $0.isCurrent || Self.hasCoachingContent($0.url) }
            .sorted { Self.isNewer($0.id, than: $1.id) }
    }

    private static func evidenceIsComplete(in sessionURL: URL) -> Bool? {
        let url = sessionURL.appendingPathComponent(FileSessionAudit.healthFilename)
        guard let data = try? Data(contentsOf: url),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = marker["state"] as? String
        else { return nil }
        switch state {
        case "complete": return true
        case "partial", "in_progress": return false
        default: return nil
        }
    }

    /// A terminal marker alone does not make an otherwise empty run worth listing.
    private static func hasCoachingContent(_ sessionURL: URL) -> Bool {
        let url = sessionURL.appendingPathComponent("jarvis-activity.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw.utf8)) else { continue }
            let shot = line.s.flatMap { name -> String? in
                guard Self.isShotName(name), FileManager.default.fileExists(atPath:
                    sessionURL.appendingPathComponent(name).path) else { return nil }
                return name
            }
            let kind = line.k.flatMap { ActivityEvent.Kind(rawValue: $0) }
            if kind == .sessionEnded {
                continue
            }
            if ActivityLog.isHumanFacing(
                message: line.m,
                imageFile: shot,
                kind: kind
            ) {
                return true
            }
        }
        return false
    }

    /// Malformed lines are skipped; an invalid or missing shot gives a text-only row (`nil` bytes).
    public func entries(for session: Session) -> [(ActivityLog.Entry, Data?)] {
        loadEntrySnapshot(for: session, retainingMostRecentInsertions: nil).entries
    }

    /// Like live Activity: keeps the newest insertions, then orders them by event time.
    public func entrySnapshot(
        for session: Session,
        retainingMostRecentInsertions maximumCount: Int
    ) -> EntrySnapshot {
        loadEntrySnapshot(
            for: session,
            retainingMostRecentInsertions: max(0, maximumCount))
    }

    private func loadEntrySnapshot(
        for session: Session,
        retainingMostRecentInsertions maximumCount: Int?
    ) -> EntrySnapshot {
        let url = session.url.appendingPathComponent("jarvis-activity.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return EntrySnapshot(entries: [], total: 0)
        }
        var out: [LoadedEntry] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw.utf8)) else { continue }
            var bytes: Data?
            var shotName: String?
            if let s = line.s, Self.isShotName(s) {
                shotName = s
                bytes = try? Data(contentsOf: session.url.appendingPathComponent(s))
            }
            if bytes == nil { shotName = nil }
            guard ActivityLog.isHumanFacing(
                message: line.m,
                imageFile: shotName,
                kind: line.k.flatMap { ActivityEvent.Kind(rawValue: $0) }
            ) else {
                continue
            }
            let insertionOrder = line.q ?? UInt64(out.count)
            let entry = ActivityLog.Entry(
                time: line.t,
                message: line.m,
                imageFile: shotName,
                occurredAt: line.o,
                insertionOrder: insertionOrder, response: line.response)
            out.append(LoadedEntry(entry: entry, imageData: bytes, occurredAt: line.o))
        }
        let total = out.count
        if let maximumCount, out.count > maximumCount {
            out = Array(out.suffix(maximumCount))
        }
        // Older sessions lack event times: keep file order, don't guess from display strings.
        guard out.allSatisfy({ $0.occurredAt?.isFinite == true }) else {
            // Strip partial metadata too, so the viewer keeps a mixed session in file order.
            let entries = out.map { loaded in
                let entry = loaded.entry
                return (
                    ActivityLog.Entry(
                        time: entry.time,
                        message: entry.message,
                        imageFile: entry.imageFile, response: entry.response),
                    loaded.imageData)
            }
            return EntrySnapshot(entries: entries, total: total)
        }
        var chronology = ConversationChronology<LoadedEntry>()
        for loaded in out {
            chronology.append(loaded, occurredAt: loaded.occurredAt!)
        }
        let entries = chronology.chronologicalItems.map {
            ($0.element.entry, $0.element.imageData)
        }
        return EntrySnapshot(entries: entries, total: total)
    }

    /// Never removes `base`, anything outside it, the current or protected sessions, or symlinks.
    public func clearHistory(preserving protectedDirectories: Set<URL> = []) {
        let curPath = current?.standardizedFileURL.path
        let protectedPaths = Set(protectedDirectories.map { $0.standardizedFileURL.path })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for name in names where Self.isSessionID(name) {
            let url = base.appendingPathComponent(name)
            if url.standardizedFileURL.path == curPath { continue }
            if protectedPaths.contains(url.standardizedFileURL.path) { continue }
            let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if vals?.isSymbolicLink == true { continue }                            // don't follow symlinks
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Counts contentless sessions too. `keep` is at least 1 so a run never deletes the session it
    /// is about to write into; protected sessions survive beyond `keep`.
    public func pruneToMostRecent(
        _ keep: Int,
        preserving protectedDirectories: Set<URL> = []
    ) {
        let keep = max(1, keep)
        let curPath = current?.standardizedFileURL.path
        let protectedPaths = Set(protectedDirectories.map { $0.standardizedFileURL.path })
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
            .filter { Self.isSessionID($0) }
            .sorted { Self.isNewer($0, than: $1) }
        for name in names.dropFirst(keep) {
            let url = base.appendingPathComponent(name)
            if url.standardizedFileURL.path == curPath { continue }
            if protectedPaths.contains(url.standardizedFileURL.path) { continue }
            let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if vals?.isSymbolicLink == true { continue }                            // don't follow symlinks
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func label(from id: String) -> String {
        SessionDirectoryID(id)?.label ?? id
    }

    private static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let left = SessionDirectoryID(lhs)?.chronologyKey ?? lhs
        let right = SessionDirectoryID(rhs)?.chronologyKey ?? rhs
        return left == right ? lhs > rhs : left > right
    }
}
