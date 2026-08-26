import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import JarvisCore

// A few cases deliberately park the synchronous disk edge. Keep their gates serial so the parallel
// repository test run never consumes several cooperative-pool threads on test-only blockers.
@Suite(.serialized) struct SessionAuditIsolationTests {
    private struct CoachingSnapshot: Equatable {
        let outcome: TurnOutcome
        let providerRequests: [Data]
        let renderedTips: [[String]]
    }

    /// `@unchecked Sendable`: the lock protects all captured requests.
    private final class RequestCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Data] = []

        func append(_ request: Data) {
            lock.withLock { storage.append(request) }
        }

        var requests: [Data] {
            lock.withLock { storage }
        }
    }

    /// Holds the worker in its first open while mailbox admission remains available.
    private final class BlockingOpenWriter: SessionAuditWriting, @unchecked Sendable {
        let openEntered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let backing = SessionAuditFileWriter()

        func openSession(at directory: URL, initialHealth: Data) throws {
            openEntered.signal()
            release.wait()
            try backing.openSession(at: directory, initialHealth: initialHealth)
        }

        func append(_ data: Data, filename: String, in directory: URL) throws {
            try backing.append(data, filename: filename, in: directory)
        }

        func replaceHealth(_ data: Data, in directory: URL) throws {
            try backing.replaceHealth(data, in: directory)
        }

        func releaseOpen() {
            release.signal()
        }
    }

    /// Fails one append, then delegates every later record to the real writer.
    private final class FailFirstAppendWriter: SessionAuditWriting, @unchecked Sendable {
        enum Failure: Error { case injected }

        let openCompleted = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let backing = SessionAuditFileWriter()
        private var storedAppendCount = 0

        var appendCount: Int {
            lock.withLock { storedAppendCount }
        }

        func openSession(at directory: URL, initialHealth: Data) throws {
            try backing.openSession(at: directory, initialHealth: initialHealth)
            openCompleted.signal()
        }

        func append(_ data: Data, filename: String, in directory: URL) throws {
            let index = lock.withLock {
                storedAppendCount += 1
                return storedAppendCount
            }
            if index == 1 { throw Failure.injected }
            try backing.append(data, filename: filename, in: directory)
        }

        func replaceHealth(_ data: Data, in directory: URL) throws {
            try backing.replaceHealth(data, in: directory)
        }
    }

    /// Fails the initial open only. The next record can retry the idempotent file setup.
    private final class FailFirstOpenWriter: SessionAuditWriting, @unchecked Sendable {
        enum Failure: Error { case injected }

        let firstOpenFailed = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let backing = SessionAuditFileWriter()
        private var didFail = false

        func openSession(at directory: URL, initialHealth: Data) throws {
            let shouldFail = lock.withLock {
                guard !didFail else { return false }
                didFail = true
                return true
            }
            if shouldFail {
                firstOpenFailed.signal()
                throw Failure.injected
            }
            try backing.openSession(at: directory, initialHealth: initialHealth)
        }

        func append(_ data: Data, filename: String, in directory: URL) throws {
            try backing.append(data, filename: filename, in: directory)
        }

        func replaceHealth(_ data: Data, in directory: URL) throws {
            try backing.replaceHealth(data, in: directory)
        }
    }

    /// Parks one selected session's first terminal marker replacement.
    private final class BlockingTerminalHealthWriter: SessionAuditWriting, @unchecked Sendable {
        let terminalHealthEntered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let backing = SessionAuditFileWriter()
        private let blockedDirectory: URL
        private var didBlock = false

        init(blockedDirectory: URL) {
            self.blockedDirectory = blockedDirectory.standardizedFileURL
        }

        func openSession(at directory: URL, initialHealth: Data) throws {
            try backing.openSession(at: directory, initialHealth: initialHealth)
        }

        func append(_ data: Data, filename: String, in directory: URL) throws {
            try backing.append(data, filename: filename, in: directory)
        }

        func replaceHealth(_ data: Data, in directory: URL) throws {
            let marker = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let state = marker?["state"] as? String
            let shouldBlock = lock.withLock {
                guard directory.standardizedFileURL == blockedDirectory,
                      state != "in_progress",
                      !didBlock
                else { return false }
                didBlock = true
                return true
            }
            if shouldBlock {
                terminalHealthEntered.signal()
                release.wait()
            }
            try backing.replaceHealth(data, in: directory)
        }

        func releaseTerminalHealth() {
            release.signal()
        }
    }

    @Test func coachingIsIdenticalWithNoAuditOrAnEnabledOverloadedOrFailingAudit() async throws {
        let enabledDirectory = ActivityLogTests.tmp()
        let overloadedDirectory = ActivityLogTests.tmp()
        let failingDirectory = ActivityLogTests.tmp()
        defer {
            try? FileManager.default.removeItem(at: enabledDirectory)
            try? FileManager.default.removeItem(at: overloadedDirectory)
            try? FileManager.default.removeItem(at: failingDirectory)
        }

        let enabled = FileSessionAudit(
            directory: enabledDirectory,
            worker: SessionAuditWorker(limits: .production, writer: SessionAuditFileWriter()))
        let enabledSnapshot = await runCoaching(traffic: enabled, coachingAttempts: enabled)
        #expect(await enabled.close() == .complete)

        let noAuditSnapshot = await runCoaching()

        let failingWriter = FailFirstAppendWriter()
        let failing = FileSessionAudit(
            directory: failingDirectory,
            worker: SessionAuditWorker(limits: .production, writer: failingWriter))
        await wait(for: failingWriter.openCompleted)
        let failingSnapshot = await runCoaching(traffic: failing, coachingAttempts: failing)
        #expect(await failing.close() == .partial)
        #expect(failingWriter.appendCount > 1)

        let blockingWriter = BlockingOpenWriter()
        let overloadedWorker = SessionAuditWorker(
            limits: .init(maxEventCount: 1, maxRetainedBytes: 4_096),
            writer: blockingWriter)
        let overloaded = FileSessionAudit(
            directory: overloadedDirectory,
            worker: overloadedWorker)
        await wait(for: blockingWriter.openEntered)
        let overloadedSnapshot = await runCoaching(
            traffic: overloaded,
            coachingAttempts: overloaded)
        blockingWriter.releaseOpen()
        #expect(await overloaded.close() == .partial)
        #expect((try healthMarker(in: overloadedDirectory)["queue_overflow"] as? Int ?? 0) > 0)

        #expect(enabledSnapshot == noAuditSnapshot)
        #expect(enabledSnapshot == overloadedSnapshot)
        #expect(enabledSnapshot == failingSnapshot)
    }

    @Test func aFullQueueDropsOnlyThatRecordAndLaterRecordingContinues() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BlockingOpenWriter()
        let worker = SessionAuditWorker(
            limits: .init(maxEventCount: 2, maxRetainedBytes: 8_192),
            writer: writer)
        let audit = FileSessionAudit(directory: directory, worker: worker)
        await wait(for: writer.openEntered)

        recordTraffic(audit, tag: "accepted-before-pressure")
        recordTraffic(audit, tag: "dropped-at-capacity")

        writer.releaseOpen()
        await waitForTrafficCount(1, in: directory)
        recordTraffic(audit, tag: "accepted-after-pressure")
        #expect(await audit.close() == .partial)

        #expect(try trafficTags(in: directory) == [
            "accepted-before-pressure",
            "accepted-after-pressure",
        ])
        let marker = try healthMarker(in: directory)
        #expect(marker["state"] as? String == "partial")
        #expect(marker["queue_overflow"] as? Int == 1)
    }

    @Test func anOversizeRecordDoesNotPreventTheNextRecord() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = SessionAuditWorker(
            limits: .init(maxEventCount: 4, maxRetainedBytes: 1_024),
            writer: SessionAuditFileWriter())
        let audit = FileSessionAudit(directory: directory, worker: worker)
        await waitForHealthMarker(in: directory)

        audit.record(
            tag: "oversize",
            request: Data(repeating: 1, count: 2_048),
            response: nil,
            status: nil,
            latencyMs: 0)
        recordTraffic(audit, tag: "small-after-oversize")

        #expect(await audit.close() == .partial)
        #expect(try trafficTags(in: directory) == ["small-after-oversize"])
        #expect(try healthMarker(in: directory)["oversize_record"] as? Int == 1)
    }

    @Test func aWriteFailureDoesNotDisableLaterRecords() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FailFirstAppendWriter()
        let audit = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(limits: .production, writer: writer))
        await wait(for: writer.openCompleted)

        recordTraffic(audit, tag: "lost-write")
        recordTraffic(audit, tag: "saved-after-write-failure")

        #expect(await audit.close() == .partial)
        #expect(writer.appendCount == 2)
        #expect(try trafficTags(in: directory) == ["saved-after-write-failure"])
        #expect(try healthMarker(in: directory)["write_failure"] as? Int == 1)
    }

    @Test func anOpenFailureCanRecoverForALaterRecord() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FailFirstOpenWriter()
        let worker = SessionAuditWorker(limits: .production, writer: writer)
        let audit = FileSessionAudit(directory: directory, worker: worker)
        await wait(for: writer.firstOpenFailed)

        recordTraffic(audit, tag: "saved-after-open-failure")

        #expect(await audit.close() == .partial)
        #expect(try trafficTags(in: directory) == ["saved-after-open-failure"])
        #expect(try healthMarker(in: directory)["open_failure"] as? Int == 1)
    }

    @Test func aSerializationFailureDoesNotPreventLaterTraffic() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = SessionAuditWorker(
            limits: .production,
            writer: SessionAuditFileWriter())
        let audit = FileSessionAudit(directory: directory, worker: worker)
        await waitForHealthMarker(in: directory)
        audit.recordStarted(
            attemptID: 1,
            wake: .trigger,
            reason: .turnEnd,
            target: BrainTarget(provider: .openAI, modelID: "gpt-5.5"),
            transcriptStartIndex: 0,
            transcriptLines: [TranscriptLine(speaker: .me, text: "hello", at: 1)],
            classifications: [],
            brainFacingTranscriptIndices: [])
        recordTraffic(audit, tag: "saved-after-serialization-failure")

        #expect(await audit.close() == .partial)
        #expect(try trafficTags(in: directory) == ["saved-after-serialization-failure"])
        #expect(try healthMarker(in: directory)["serialization_failure"] as? Int == 1)
    }

    @Test func aReplacementSessionCanStartWhileTheOldAuditCloses() async throws {
        let oldDirectory = ActivityLogTests.tmp()
        let newDirectory = ActivityLogTests.tmp()
        defer {
            try? FileManager.default.removeItem(at: oldDirectory)
            try? FileManager.default.removeItem(at: newDirectory)
        }
        let writer = BlockingTerminalHealthWriter(blockedDirectory: oldDirectory)
        let worker = SessionAuditWorker(limits: .production, writer: writer)
        let oldAudit = FileSessionAudit(directory: oldDirectory, worker: worker)
        await waitForHealthMarker(in: oldDirectory)
        recordTraffic(oldAudit, tag: "old-session")
        await waitForTrafficCount(1, in: oldDirectory)

        let oldClose = Task { await oldAudit.close() }
        await wait(for: writer.terminalHealthEntered)

        let newAudit = FileSessionAudit(directory: newDirectory, worker: worker)
        recordTraffic(newAudit, tag: "new-session")

        writer.releaseTerminalHealth()
        #expect(await oldClose.value == .complete)
        #expect(await newAudit.close() == .complete)
        #expect(try trafficTags(in: newDirectory) == ["new-session"])
    }

    @Test func abandonReturnsBeforeDiskAndLeavesIncompleteEvidence() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BlockingTerminalHealthWriter(blockedDirectory: directory)
        let worker = SessionAuditWorker(limits: .production, writer: writer)
        let audit = FileSessionAudit(directory: directory, worker: worker)
        await waitForHealthMarker(in: directory)

        audit.abandon()
        await wait(for: writer.terminalHealthEntered)
        #expect(try healthMarker(in: directory)["state"] as? String == "in_progress")

        writer.releaseTerminalHealth()
        #expect(await audit.close() == .partial)
        #expect(try healthMarker(in: directory)["state"] as? String == "partial")
    }

    @Test func aClosedAuditNeverChanges() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = SessionAuditWorker(
            limits: .production,
            writer: SessionAuditFileWriter())
        let audit = FileSessionAudit(directory: directory, worker: worker)
        await waitForHealthMarker(in: directory)
        recordTraffic(audit, tag: "before-close")
        #expect(await audit.close() == .complete)
        let trafficURL = directory.appendingPathComponent(FileSessionAudit.brainTrafficFilename)
        let healthURL = directory.appendingPathComponent(FileSessionAudit.healthFilename)
        let trafficBefore = try Data(contentsOf: trafficURL)
        let healthBefore = try Data(contentsOf: healthURL)

        recordTraffic(audit, tag: "after-close")
        await Task.yield()

        #expect(try Data(contentsOf: trafficURL) == trafficBefore)
        #expect(try Data(contentsOf: healthURL) == healthBefore)
        #expect(try healthMarker(in: directory)["state"] as? String == "complete")
    }

    private func runCoaching(
        traffic: (any BrainTrafficAuditing)? = nil,
        coachingAttempts: (any CoachingAttemptAuditing)? = nil
    ) async -> CoachingSnapshot {
        let requests = RequestCapture()
        let response = Data(
            #"{"status":"completed","output":[{"type":"function_call","call_id":"s1","name":"speak","arguments":"{\"lines\":[\"same tip\"]}"}]}"#.utf8)
        let client = OpenAIBrainClient(
            apiKey: "test-key",
            model: "gpt-5.5",
            traffic: traffic,
            send: { request in
                let body = request.httpBody ?? Data()
                let object = try JSONSerialization.jsonObject(with: body)
                requests.append(try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]))
                return (
                    response,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil))
            })
        let target = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let overlay = FakeOverlay()
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default,
            transcript: transcript,
            route: ConfiguredBrainRoute(targets: [
                ConfiguredBrainTarget(target: target, brain: client),
            ]),
            screen: FakeScreen(),
            overlay: overlay,
            clock: ManualClock(),
            coachingAttempts: coachingAttempts,
            automaticAttemptDelay: { _ in },
            activityLog: ActivityLog())
        transcript.append(.init(
            speaker: .me,
            text: "compare audit observer behavior",
            at: 1))

        return CoachingSnapshot(
            outcome: await driver.handleTrigger(.turnEnd),
            providerRequests: requests.requests,
            renderedTips: overlay.rendered)
    }

    private func recordTraffic(_ audit: FileSessionAudit, tag: String) {
        audit.record(
            tag: tag,
            request: Data(#"{"model":"gpt-5.5"}"#.utf8),
            response: Data(#"{"status":"completed"}"#.utf8),
            status: 200,
            latencyMs: 10)
    }

    private func wait(for semaphore: DispatchSemaphore) async {
        let reached = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
            }
        }
        #expect(reached)
    }

    private func waitForHealthMarker(in directory: URL) async {
        let marker = directory.appendingPathComponent(FileSessionAudit.healthFilename)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: marker.path),
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    private func waitForTrafficCount(_ expected: Int, in directory: URL) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (try? trafficTags(in: directory).count) != expected,
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect((try? trafficTags(in: directory).count) == expected)
    }

    private func trafficTags(in directory: URL) throws -> [String] {
        let text = try String(
            contentsOf: directory.appendingPathComponent(
                FileSessionAudit.brainTrafficFilename),
            encoding: .utf8)
        // Local JSONL parse: the loss-aware `JSONLRecords` reader lives with the sealed-session
        // consumers in JarvisEvaluation, and this test only needs the valid records' tags.
        return text.split(separator: "\n")
            .compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
            .compactMap { $0["tag"] as? String }
    }

    private func healthMarker(in directory: URL) throws -> [String: Any] {
        let data = try Data(
            contentsOf: directory.appendingPathComponent(FileSessionAudit.healthFilename))
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
