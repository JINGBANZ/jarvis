import Foundation

extension AgentCLIDetector {
    /// Finder does not inherit nvm's shell PATH. Inspect its versioned installs without sourcing
    /// startup scripts, which can hang or present UI during live provider preflight. An explicit
    /// PATH selection still wins; otherwise use the newest installed version containing the CLI.
    static func nvmDirectories(home: URL) -> [String] {
        let versions = home.appendingPathComponent(".nvm/versions/node")
        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: versions.path)) ?? []
        return entries.filter { name in
            let components = name.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
            return name.hasPrefix("v") && components.count == 3
                && components.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
        }.sorted {
            $0.compare($1, options: .numeric) == .orderedDescending
        }.map { versions.appendingPathComponent($0).appendingPathComponent("bin").path }
    }
}
