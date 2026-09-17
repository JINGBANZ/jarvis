import Foundation

extension AgentCLIDetector {
    /// Finder doesn't inherit nvm's shell PATH. Scan its installs, newest first, instead of
    /// sourcing startup scripts, which can hang or present UI.
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
