import Foundation
import Testing
@testable import JarvisCore

@Suite struct SessionDirectoryIDTests {
    @Test func newIDsCarryBuildIdentityWithoutIO() throws {
        let release = try #require(SessionDirectoryID(SessionDirectoryID.make(
            isDevelopmentBuild: false, version: "0.2.2")))
        #expect(release.releaseVersion == "0.2.2")
        #expect(!release.isDevelopment)
        let dev = try #require(SessionDirectoryID(SessionDirectoryID.make(
            isDevelopmentBuild: true, version: "0.2.2")))
        #expect(dev.isDevelopment)
        #expect(dev.releaseVersion == nil)
        let unknown = try #require(SessionDirectoryID(SessionDirectoryID.make(
            isDevelopmentBuild: false, version: nil)))
        #expect(unknown.releaseVersion == nil)
        #expect(!unknown.isDevelopment)
    }

    @Test(arguments: ["../v0.2.2-2026-09-12_10-00-00_abcd", "v$(id)-2026-09-12_10-00-00_abcd",
                      "dev-2026-09-12_10-00-00_abcd/child", "v0.2.2-2026-09-12_10-00-00_abcd\n",
                      "unknown-2026-09-12_10-00-00_abcd"])
    func rejectsUnsafeOrMalformedDirectoryNames(_ name: String) {
        #expect(SessionDirectoryID(name) == nil)
    }

    @Test func prefixesDoNotChangeTimestampOrLabel() throws {
        let timestamp = "2026-09-12_10-00-00_abcd"
        for prefix in ["", "dev-", "v0.2.2-"] {
            let parsed = try #require(SessionDirectoryID(prefix + timestamp))
            #expect(parsed.chronologyKey == timestamp)
            #expect(parsed.label == "2026-09-12 10:00:00")
        }
    }
}
