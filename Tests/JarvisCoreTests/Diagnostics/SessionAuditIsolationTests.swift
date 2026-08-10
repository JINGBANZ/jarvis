import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import JarvisCore

// Several cases intentionally park a synchronous disk writer. Keep those gates serial so the full
// default-parallel test run never consumes multiple cooperative-pool threads on test-only blockers.
@Suite(.serialized) struct SessionAuditIsolationTests {
    private struct CoachingSnapshot: Equatable {
        let outcome: TurnOutcome
        let providerRequests: [Data]
        let renderedTips: [[String]]
    }

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

    /// Holds the worker inside its first file operation while leaving mailbox admission available.
    private final class BlockingWriter: SessionAuditWriting, @unchecked Sendable {
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

        func replaceHealth(
            _ data: Data,
            in directory: URL,
            shouldCommit: @Sendable () -> Bool
        ) throws -> Bool {
            try backing.replaceHealth(data, in: directory, shouldCommit: shouldCommit)
        }

        func releaseOpen() {
            release.signal()
        }
    }

    /// Opens normally, then fails the first append. A correct session stops calling it afterward.
    private final class FailingAppendWriter: SessionAuditWriting, @unchecked Sendable {
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
            lock.withLock { storedAppendCount += 1 }
            throw Failure.injected
        }

        func replaceHealth(
            _ data: Data,
            in directory: URL,
            shouldCommit: @Sendable () -> Bool
        ) throws -> Bool {
            try backing.replaceHealth(data, in: directory, shouldCommit: shouldCommit)
        }
    }

    /// Fails before either JSONL file exists, but still permits the close marker to be installed.
    private final class FailingOpenWriter: SessionAuditWriting, @unchecked Sendable {
        enum Failure: Error { case injected }

        let openAttempted = DispatchSemaphore(value: 0)
        private let backing = SessionAuditFileWriter()

        func openSession(at directory: URL, initialHealth: Data) throws {
            openAttempted.signal()
            throw Failure.injected
        }

        func append(_ data: Data, filename: String, in directory: URL) throws {
            Issue.record("append must not run after session open fails")
        }

        func replaceHealth(
            _ data: Data,
            in directory: URL,
            shouldCommit: @Sendable () -> Bool
        ) throws -> Bool {
            try backing.replaceHealth(data, in: directory, shouldCommit: shouldCommit)
        }
    }

    /// Parks the final health replacement after the worker has already snapshotted complete state.
    private final class BlockingFinalHealthWriter: SessionAuditWriting, @unchecked Sendable {
        let finalHealthEntered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let backing = SessionAuditFileWriter()
        private var hasBlocked = false
        private var storedBlockedHealth: Data?

        var blockedHealth: Data? {
            lock.withLock { storedBlockedHealth }
        }

        func openSession(at directory: URL, initialHealth: Data) throws {
            try backing.openSession(at: directory, initialHealth: initialHealth)
        }

        func append(_ data: Data, filename: String, in directory: URL) throws {
            try backing.append(data, filename: filename, in: directory)
        }

        func replaceHealth(
            _ data: Data,
            in directory: URL,
            shouldCommit: @Sendable () -> Bool
        ) throws -> Bool {
            let shouldBlock = lock.withLock {
                guard !hasBlocked else { return false }
                hasBlocked = true
                storedBlockedHealth = data
                return true
            }
            if shouldBlock {
                finalHealthEntered.signal()
                release.wait()
            }
            return try backing.replaceHealth(
                data,
                in: directory,
                shouldCommit: shouldCommit)
        }

        func releaseFinalHealth() {
            release.signal()
        }
    }

    @Test func coachingIsIdenticalWhenAuditIsEnabledDisabledOverloadedOrFailing() async throws {
        let enabledDirectory = ActivityLogTests.tmp()
        let overloadedDirectory = ActivityLogTests.tmp()
        let failingDirectory = ActivityLogTests.tmp()
        defer {
            try? FileManager.default.removeItem(at: enabledDirectory)
            try? FileManager.default.removeItem(at: overloadedDirectory)
            try? FileManager.default.removeItem(at: failingDirectory)
        }

        let enabledWorker = SessionAuditWorker(
            limits: .production,
            writer: SessionAuditFileWriter())
        let enabled = FileSessionAudit(directory: enabledDirectory, worker: enabledWorker)
        let enabledSnapshot = await runCoaching(
            traffic: enabled,
            coachingAttempts: enabled)
        #expect(await enabled.close(deadline: .seconds(5)) == .complete)

        let noAuditSnapshot = await runCoaching()

        let failingWriter = FailingAppendWriter()
        let failingWorker = SessionAuditWorker(
            limits: .production,
            writer: failingWriter)
        let failing = FileSessionAudit(directory: failingDirectory, worker: failingWorker)
        await wait(for: failingWriter.openCompleted)
        await waitUntilIdle(failingWorker)
        let failingSnapshot = await runCoaching(
            traffic: failing,
            coachingAttempts: failing)
        #expect(await failing.close(deadline: .seconds(5)) == .partial)
        #expect(failingWriter.appendCount == 1)
        #expect(failing.healthSnapshot.writeFailure == 1)

        let blockingWriter = BlockingWriter()
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
        #expect(overloadedWorker.retainedSnapshot().eventCount == 1)
        #expect(overloaded.healthSnapshot.queueOverflow > 0)
        blockingWriter.releaseOpen()
        await waitUntilIdle(overloadedWorker)
        #expect(await overloaded.close(deadline: .seconds(5)) == .partial)

        #expect(enabledSnapshot == noAuditSnapshot)
        #expect(enabledSnapshot == overloadedSnapshot)
        #expect(enabledSnapshot == failingSnapshot)
    }

    @Test func mailboxBoundsCountAndBytesAndMarksDroppedEvidence() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BlockingWriter()
        let limits = SessionAuditWorker.Limits(
            maxEventCount: 3,
            maxRetainedBytes: 1_024)
        let worker = SessionAuditWorker(limits: limits, writer: writer)
        let audit = FileSessionAudit(directory: directory, worker: worker)
        await wait(for: writer.openEntered)

        for _ in 0..<20 {
            audit.record(
                tag: "coach",
                request: Data("{}".utf8),
                response: nil,
                status: nil,
                latencyMs: 1)
        }
        let beforeOversize = worker.retainedSnapshot()
        audit.record(
            tag: "coach",
            request: Data(repeating: 0x41, count: 2_048),
            response: nil,
            status: nil,
            latencyMs: 1)
        let retained = worker.retainedSnapshot()

        #expect(beforeOversize.eventCount <= limits.maxEventCount)
        #expect(beforeOversize.approximateBytes <= limits.maxRetainedBytes)
        #expect(retained == beforeOversize)
        #expect(audit.healthSnapshot.queueOverflow > 0)
        #expect(audit.healthSnapshot.oversizeRecord == 1)

        writer.releaseOpen()
        await waitUntilIdle(worker)
        #expect(await audit.close(deadline: .seconds(5)) == .partial)
        let marker = try healthMarker(in: directory)
        #expect(marker["state"] as? String == "partial")
        #expect((marker["queue_overflow"] as? Int ?? 0) > 0)
        #expect(marker["oversize_record"] as? Int == 1)
    }

    @Test func closeTimeoutReturnsWithoutReleasingBlockedDiskAndLeavesPartialMarker() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BlockingWriter()
        let worker = SessionAuditWorker(
            limits: .production,
            writer: writer)
        let audit = FileSessionAudit(directory: directory, worker: worker)
        await wait(for: writer.openEntered)

        #expect(await audit.close(deadline: .zero) == .partial)
        #expect(audit.healthSnapshot.closeTimeout > 0)

        writer.releaseOpen()
        await waitUntilIdle(worker)
        let marker = try healthMarker(in: directory)
        #expect(marker["state"] as? String == "partial")
        #expect((marker["close_timeout"] as? Int ?? 0) > 0)
    }

    @Test func finalHealthWriteCrossingDeadlineCannotLeaveCompleteMarker() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BlockingFinalHealthWriter()
        let worker = SessionAuditWorker(limits: .production, writer: writer)
        let audit = FileSessionAudit(directory: directory, worker: worker)
        await waitUntilIdle(worker)

        let close = Task { await audit.close(deadline: .milliseconds(20)) }
        await wait(for: writer.finalHealthEntered)
        let blockedMarker = try #require(writer.blockedHealth)
        let blockedObject = try #require(
            JSONSerialization.jsonObject(with: blockedMarker) as? [String: Any])
        #expect(blockedObject["state"] as? String == "complete")
        #expect(await close.value == .partial)
        let markerWhileBlocked = try healthMarker(in: directory)
        #expect(markerWhileBlocked["state"] as? String == "open")
        #expect(markerWhileBlocked["closed"] as? Bool == false)

        writer.releaseFinalHealth()
        await waitUntilIdle(worker)
        let marker = try healthMarker(in: directory)
        #expect(marker["state"] as? String == "partial")
        #expect((marker["close_timeout"] as? Int ?? 0) > 0)
    }

    @Test func synchronousCloseWaitsForDurableCompleteMarker() throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = SessionAuditWorker(
            limits: .production,
            writer: SessionAuditFileWriter())
        let audit = FileSessionAudit(directory: directory, worker: worker)

        #expect(audit.closeSynchronously(deadline: .seconds(5)) == .complete)
        let marker = try healthMarker(in: directory)
        #expect(marker["state"] as? String == "complete")
        #expect(marker["closed"] as? Bool == true)
    }

    @Test func openFailureDisablesCaptureAndIsVisibleInHealthMarker() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FailingOpenWriter()
        let worker = SessionAuditWorker(
            limits: .production,
            writer: writer)
        let audit = FileSessionAudit(directory: directory, worker: worker)
        await wait(for: writer.openAttempted)
        await waitUntilIdle(worker)

        audit.record(
            tag: "coach",
            request: Data("{}".utf8),
            response: nil,
            status: nil,
            latencyMs: 1)
        #expect(await audit.close(deadline: .seconds(5)) == .partial)
        #expect(audit.healthSnapshot.openFailure == 1)
        let marker = try healthMarker(in: directory)
        #expect(marker["open_failure"] as? Int == 1)
    }

    @Test func mismatchedAttemptEvidenceIsContainedAsPartialInsteadOfTrapping() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = SessionAuditWorker(
            limits: .production,
            writer: SessionAuditFileWriter())
        let audit = FileSessionAudit(directory: directory, worker: worker)
        audit.recordStarted(
            attemptID: 1,
            wake: .trigger,
            reason: .turnEnd,
            target: BrainTarget(provider: .openAI, modelID: "gpt-5.5"),
            transcriptStartIndex: 0,
            transcriptLines: [TranscriptLine(speaker: .me, text: "hello", at: 1)],
            classifications: [],
            brainFacingTranscriptIndices: [])

        #expect(await audit.close(deadline: .seconds(5)) == .partial)
        #expect(audit.healthSnapshot.serializationFailure == 1)
        let marker = try healthMarker(in: directory)
        #expect(marker["serialization_failure"] as? Int == 1)
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
            automaticAttemptDelay: { _ in })
        transcript.append(.init(
            speaker: .me,
            text: "compare audit observer behavior",
            at: 1))

        return CoachingSnapshot(
            outcome: await driver.handleTrigger(.turnEnd),
            providerRequests: requests.requests,
            renderedTips: overlay.rendered)
    }

    private func wait(for semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }

    private func waitUntilIdle(_ worker: SessionAuditWorker) async {
        while worker.retainedSnapshot().eventCount > 0 {
            await Task.yield()
        }
    }

    private func healthMarker(in directory: URL) throws -> [String: Any] {
        let data = try Data(
            contentsOf: directory.appendingPathComponent(FileSessionAudit.healthFilename))
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
