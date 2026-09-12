import Foundation
import Testing
import JarvisBrainProviders
@testable import JarvisEvaluation

@Suite struct ReleaseSourceStoreTests {
    @Test func recordedVersionFetchesItsOwnSourceAndDiscardsItAfterUse() async throws {
        let fixture = tmp()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("runs")
        let archive = try await releaseArchive("0.2.1", in: fixture)
        let store = ReleaseSourceStore(root: root) { url, destination in
            #expect(url.absoluteString
                    == "https://github.com/JINGBANZ/jarvis/archive/refs/tags/v0.2.1.tar.gz")
            try FileManager.default.copyItem(at: archive, to: destination)
        }
        let checkout = try await store.fetch(version: "0.2.1", fallbackVersion: "0.2.2")
        #expect(checkout.version == "0.2.1")
        #expect(checkout.directory.lastPathComponent == "jarvis-0.2.1")
        #expect(try String(contentsOf: checkout.directory.appendingPathComponent("Package.swift"),
                           encoding: .utf8) == "// fixture 0.2.1")
        checkout.discard()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func networkFailureNamesTheRecordedVersionAndNeverTriesAnother() async throws {
        let root = tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let requested = Requests()
        let store = ReleaseSourceStore(root: root) { url, _ in
            await requested.record(url.lastPathComponent)
            throw URLError(.notConnectedToInternet)
        }
        await #expect(throws: ReleaseSourceStore.Failure.fetchFailed("0.2.1")) {
            _ = try await store.fetch(version: "0.2.1", fallbackVersion: "0.2.2")
        }
        // The running release lives behind the same unreachable network, so retrying it could only
        // fail again while renaming the failure after a version the user never selected.
        #expect(await requested.all == ["v0.2.1.tar.gz"])
    }

    @Test func missingTagFallsBackToTheRunningRelease() async throws {
        let fixture = tmp()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let archive = try await releaseArchive("0.2.2", in: fixture)
        let requested = Requests()
        let store = ReleaseSourceStore(root: fixture.appendingPathComponent("runs")) { url, destination in
            await requested.record(url.lastPathComponent)
            if url.lastPathComponent == "v0.2.1.tar.gz" { throw URLError(.fileDoesNotExist) }
            try FileManager.default.copyItem(at: archive, to: destination)
        }
        let checkout = try await store.fetch(version: "0.2.1", fallbackVersion: "0.2.2")
        #expect(checkout.version == "0.2.2")
        #expect(await requested.all == ["v0.2.1.tar.gz", "v0.2.2.tar.gz"])
        checkout.discard()
    }

    @Test func missingTagWithoutAFallbackReportsTheRecordedVersion() async throws {
        let root = tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReleaseSourceStore(root: root) { _, _ in throw URLError(.fileDoesNotExist) }
        await #expect(throws: ReleaseSourceStore.Failure.tagNotFound("0.2.1")) {
            _ = try await store.fetch(version: "0.2.1", fallbackVersion: nil)
        }
    }

    @Test func unrecordedVersionUsesTheRunningRelease() async throws {
        let fixture = tmp()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let archive = try await releaseArchive("0.2.2", in: fixture)
        let store = ReleaseSourceStore(root: fixture.appendingPathComponent("runs")) { url, destination in
            #expect(url.lastPathComponent == "v0.2.2.tar.gz")
            try FileManager.default.copyItem(at: archive, to: destination)
        }
        let checkout = try await store.fetch(version: nil, fallbackVersion: "0.2.2")
        #expect(checkout.version == "0.2.2")
        checkout.discard()
    }

    @Test func noVersionAndNoRunningReleaseReportsNoSource() async throws {
        let root = tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReleaseSourceStore(root: root) { _, _ in Issue.record("Fetched without a version") }
        await #expect(throws: ReleaseSourceStore.Failure.noAvailableSource) {
            _ = try await store.fetch(version: nil, fallbackVersion: nil)
        }
    }

    @Test func failedUnpackLeavesNoTreeBehindAndRetryStillWorks() async throws {
        let fixture = tmp()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("runs")
        let archive = try await releaseArchive("0.2.1", in: fixture)
        let bytes = try Data(contentsOf: archive)
        let broken = ReleaseSourceStore(root: root) { _, destination in
            try bytes.prefix(bytes.count / 2).write(to: destination)
        }
        await #expect(throws: ReleaseSourceStore.Failure.unpackFailed("0.2.1")) {
            _ = try await broken.checkout(version: "0.2.1")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let repaired = ReleaseSourceStore(root: root) { _, destination in
            try FileManager.default.copyItem(at: archive, to: destination)
        }
        let checkout = try await repaired.checkout(version: "0.2.1")
        #expect(FileManager.default.fileExists(
            atPath: checkout.directory.appendingPathComponent("Package.swift").path))
        checkout.discard()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func sourceTreeIsOwnerOnly() async throws {
        let fixture = tmp()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("runs")
        let archive = try await releaseArchive("0.2.1", in: fixture)
        let store = ReleaseSourceStore(root: root) { _, destination in
            try FileManager.default.copyItem(at: archive, to: destination)
        }
        let checkout = try await store.checkout(version: "0.2.1")
        let container = try #require(try FileManager.default
            .contentsOfDirectory(atPath: root.path).first)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent(container).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        checkout.discard()
    }

    @Test func invalidVersionDoesNotReachFetcherOrFilesystem() async throws {
        let fixture = tmp()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("runs")
        let store = ReleaseSourceStore(root: root) { _, _ in Issue.record("Invalid version fetched") }
        await #expect(throws: ReleaseSourceStore.Failure.invalidVersion) {
            _ = try await store.checkout(version: "../0.2.1;id")
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func cancellationReachesFetcherAndLeavesNoTree() async throws {
        let root = tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let store = ReleaseSourceStore(root: root) { _, destination in
            try Data("partial download".utf8).write(to: destination)
            signal.yield(())
            try await Task.sleep(for: .seconds(60))
        }
        let task = Task { try await store.checkout(version: "0.2.1") }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func cancellationNeverFallsBackToAnotherVersion() async throws {
        let root = tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let requested = Requests()
        let store = ReleaseSourceStore(root: root) { url, _ in
            await requested.record(url.lastPathComponent)
            signal.yield(())
            try await Task.sleep(for: .seconds(60))
        }
        let task = Task { try await store.fetch(version: "0.2.1", fallbackVersion: "0.2.2") }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await requested.all == ["v0.2.1.tar.gz"])
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .fileDoesNotExist])
    func sourceFailuresNameVersionAndPreserveSavedReport(_ code: URLError.Code) async throws {
        let root = tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let report = session.appendingPathComponent(AgenticEvaluation.reportFilename)
        try Data("Previous report".utf8).write(to: report)
        let store = ReleaseSourceStore(root: root.appendingPathComponent("runs")) { _, _ in
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

    private actor Requests {
        private var names: [String] = []
        func record(_ name: String) { names.append(name) }
        var all: [String] { names }
    }
}
