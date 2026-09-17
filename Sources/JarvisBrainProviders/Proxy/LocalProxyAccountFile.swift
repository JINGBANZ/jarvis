import Foundation
import JarvisCore

/// CLIProxyAPI names these `claude-<hash>-<email>.json` and `codex-<hash>-<email>[-<plan>].json`.
/// Only the name is parsed, so listing accounts never loads a token into memory.
public struct LocalProxyAccountFile: Sendable, Equatable {
    public let url: URL
    public let provider: BrainProvider
    public let email: String?
    /// A ChatGPT plan such as `plus`; nil for Claude.
    public let plan: String?

    public init?(url: URL) {
        let name = url.lastPathComponent
        guard name.hasSuffix(".json") else { return nil }
        let stem = name.dropLast(".json".count)
        let rest: Substring
        if stem.hasPrefix("claude-") {
            provider = .claudeSubscription
            rest = stem.dropFirst("claude-".count)
        } else if stem.hasPrefix("codex-") {
            provider = .codexSubscription
            rest = stem.dropFirst("codex-".count)
        } else {
            return nil
        }
        self.url = url
        let afterHash = rest.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init)
        var account = afterHash ?? ""
        var plan: String?
        // A plan follows the email's domain, which cannot end in a hyphenated label.
        if provider == .codexSubscription, let lastDot = account.lastIndex(of: "."),
           let hyphen = account[lastDot...].lastIndex(of: "-") {
            plan = String(account[account.index(after: hyphen)...])
            account = String(account[..<hyphen])
        }
        self.plan = plan
        email = account.contains("@") ? account : nil
    }

    public static func all(in directory: URL, for provider: BrainProvider) -> [LocalProxyAccountFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap(LocalProxyAccountFile.init(url:))
            .filter { $0.provider == provider }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }
}
