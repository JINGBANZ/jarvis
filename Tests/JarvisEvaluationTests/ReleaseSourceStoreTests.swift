import Foundation
import Testing
import JarvisBrainProviders
@testable import JarvisEvaluation

@Suite struct ReleaseSourceStoreTests {
    @Test func cacheHitSkipsFetcherAndRefreshesRecency() async throws {
        let root = tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try cached("0.2.1", in: root, lastUsed: .distantPast)
        let store = ReleaseSourceStore(root: root) { _, _ in Issue.record("Cache hit fetched source") }
        #expect(try await store.directory(for: "0.2.1") == checkout)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let used = try checkout.deletingLastPathComponent().resourceValues(forKeys: [.contentModificationDateKey])
        #expect(try #require(used.contentModificationDate) > Date().addingTimeInterval(-30))
    }

    @Test func fetchPublishesInnerCheckoutAndPrunesLeastRecentlyUsed() async throws {
        let fixture = tmp()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("cache")
        _ = try cached("0.2.1", in: root, lastUsed: Date(timeIntervalSince1970: 1))
        _ = try cached("0.2.2", in: root, lastUsed: Date(timeIntervalSince1970: 2))
        _ = try cached("0.2.3", in: root, lastUsed: Date(timeIntervalSince1970: 3))
        let archive = try await archive("0.2.4", in: fixture)
        let store = ReleaseSourceStore(root: root) { url, destination in
            #expect(url.absoluteString == "https://github.com/JINGBANZ/jarvis/archive/refs/tags/v0.2.4.tar.gz")
            try FileManager.default.copyItem(at: archive, to: destination)
        }
        _ = try await store.directory(for: "0.2.1")
        let checkout = try await store.directory(for: "0.2.4")
        #expect(checkout == root.appendingPathComponent("v0.2.4/jarvis-0.2.4"))
        #expect(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("Package.swift").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
                == ["v0.2.1", "v0.2.3", "v0.2.4"])
    }

    @Test func failedUnpackNeverBecomesCacheHit() async throws {
        let fixture = tmp()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("cache")
        let archive = try await archive("0.2.1", in: fixture)
        let bytes = try Data(contentsOf: archive)
        let broken = ReleaseSourceStore(root: root) { _, destination in
            try bytes.prefix(bytes.count / 2).write(to: destination)
        }
        await #expect(throws: ReleaseSourceStore.Failure.cacheFailed("0.2.1")) {
            _ = try await broken.directory(for: "0.2.1")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let repaired = ReleaseSourceStore(root: root) { _, destination in
            try FileManager.default.copyItem(at: archive, to: destination)
        }
        let checkout = try await repaired.directory(for: "0.2.1")
        #expect(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("Package.swift").path))
    }

    @Test func invalidVersionDoesNotReachFetcherOrFilesystem() async throws {
        let fixture = tmp()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("cache")
        let store = ReleaseSourceStore(root: root) { _, _ in Issue.record("Invalid version fetched") }
        await #expect(throws: ReleaseSourceStore.Failure.invalidVersion) {
            _ = try await store.directory(for: "../0.2.1;id")
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func cancellationReachesFetcherAndLeavesNoCache() async throws {
        let root = tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let store = ReleaseSourceStore(root: root) { _, destination in
            try Data("partial download".utf8).write(to: destination)
            signal.yield(())
            try await Task.sleep(for: .seconds(60))
        }
        let task = Task { try await store.directory(for: "0.2.1") }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .fileDoesNotExist])
    func sourceFailuresNameVersionAndPreserveSavedReport(_ code: URLError.Code) async throws {
        let root = tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let report = session.appendingPathComponent(AgenticEvaluation.reportFilename)
        try Data("Previous report".utf8).write(to: report)
        let store = ReleaseSourceStore(root: root.appendingPathComponent("source")) { _, _ in
            throw URLError(code)
        }
        let evaluator = AgenticEvaluator(source: .release(version: "0.2.1"), sourceStore: store)
        let expected: ReleaseSourceStore.Failure = code == .fileDoesNotExist
            ? .tagNotFound("0.2.1") : .fetchFailed("0.2.1")
        await #expect(throws: expected) { _ = try await evaluator.evaluate(sessionDirectory: session) }
        #expect(expected.localizedDescription.contains("0.2.1"))
        #expect(!expected.localizedDescription.contains("jarvis-debug.log"))
        #expect(try String(contentsOf: report, encoding: .utf8) == "Previous report")
    }

    private func cached(_ version: String, in root: URL, lastUsed: Date) throws -> URL {
        let checkout = root.appendingPathComponent("v\(version)/jarvis-\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try Data("// fixture".utf8).write(to: checkout.appendingPathComponent("Package.swift"))
        try FileManager.default.setAttributes([.modificationDate: lastUsed],
            ofItemAtPath: checkout.deletingLastPathComponent().path)
        return checkout
    }

    private func archive(_ version: String, in fixture: URL) async throws -> URL {
        let source = fixture.appendingPathComponent("jarvis-\(version)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("// swift-tools-version:6.0".utf8).write(to: source.appendingPathComponent("Package.swift"))
        let archive = fixture.appendingPathComponent("fixture.tar.gz")
        let output = try await AgentCLIProcessRunner.run(AgentCLIRun(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-czf", archive.path, "-C", fixture.path, source.lastPathComponent],
            stdin: nil, workingDirectory: fixture, timeout: 5))
        #expect(output.exitCode == 0)
        return archive
    }
}
