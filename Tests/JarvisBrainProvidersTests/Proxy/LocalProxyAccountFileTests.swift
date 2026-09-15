import Foundation
import JarvisBrainProviders
import JarvisCore
import Testing

@Suite struct LocalProxyAccountFileTests {
    private func file(_ name: String) -> LocalProxyAccountFile? {
        LocalProxyAccountFile(url: URL(fileURLWithPath: "/auth/\(name)"))
    }

    @Test func readsTheAccountFromTheHelpersFileNames() throws {
        let claude = try #require(file("claude-0e6a52df-ada@example.com.json"))
        #expect(claude.provider == .claudeSubscription)
        #expect(claude.email == "ada@example.com")
        #expect(claude.plan == nil)

        let codex = try #require(file("codex-0b4df214-ada@my-lab.example.com-plus.json"))
        #expect(codex.provider == .codexSubscription)
        #expect(codex.email == "ada@my-lab.example.com")
        #expect(codex.plan == "plus")

        let planless = try #require(file("codex-0b4df214-ada@my-lab.example.com.json"))
        #expect(planless.email == "ada@my-lab.example.com")
        #expect(planless.plan == nil)
    }

    @Test func ignoresEverythingElseInTheAuthDirectory() {
        for name in ["logs", "config.yaml", "claude-0e6a52df-ada@example.com.json.tmp",
                     "gemini-1a2b3c4d-ada@example.com.json"] {
            #expect(file(name) == nil)
        }
    }

    @Test func listsOnlyTheRequestedSubscriptionInNameOrder() throws {
        let directory = tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["codex-2-b@example.com.json", "claude-1-a@example.com.json",
                     "codex-1-a@example.com-pro.json", "notes.txt"] {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent(name).path, contents: Data("{}".utf8))
        }
        #expect(LocalProxyAccountFile.all(in: directory, for: .codexSubscription).map(\.email)
            == ["a@example.com", "b@example.com"])
        #expect(LocalProxyAccountFile.all(in: directory, for: .claudeSubscription).count == 1)
        #expect(LocalProxyAccountFile.all(in: directory, for: .openAI).isEmpty)
    }
}
