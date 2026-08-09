import Foundation

/// Prunes persisted transcription benchmark runs without following links or touching unrelated
/// children. The current run counts toward the cap and is always retained.
public struct TranscriptionBenchmarkRunStore: Sendable {
    private let base: URL
    private let current: URL

    public init(base: URL, current: URL) {
        self.base = base.standardizedFileURL
        self.current = current.standardizedFileURL
    }

    public func pruneToMostRecent(_ keep: Int) throws {
        guard current.deletingLastPathComponent().path == base.path,
              Self.isRunID(current.lastPathComponent) else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        let fileManager = FileManager.default
        let names = try fileManager.contentsOfDirectory(atPath: base.path)
        var runs: [URL] = []
        for name in names where Self.isRunID(name) {
            let url = base.appendingPathComponent(name, isDirectory: true).standardizedFileURL
            guard url.deletingLastPathComponent().path == base.path else { continue }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            runs.append(url)
        }

        guard runs.contains(where: { $0.path == current.path }) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let keep = max(1, keep)
        let newestPastRuns = runs
            .filter { $0.path != current.path }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(keep - 1)
        let retainedPaths = Set(([current] + newestPastRuns).map(\.path))
        for run in runs where !retainedPaths.contains(run.path) {
            try fileManager.removeItem(at: run)
        }
    }

    /// `yyyy-MM-dd_HH-mm-ss-PID`, as produced by `scripts/transcription-benchmark.sh`.
    private static func isRunID(_ value: String) -> Bool {
        value.wholeMatch(
            of: /^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]+$/
        ) != nil
    }
}
