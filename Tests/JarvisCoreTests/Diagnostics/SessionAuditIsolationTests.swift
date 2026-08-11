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

    /// `@unchecked Sendable`: `lock` protects every read and write of `storage`.
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

    /// `@unchecked Sendable`: `lock` protects the sole mutable flag.
    private final class CompletionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false

        func mark() {
            lock.withLock { storage = true }
        }

        var isMarked: Bool {
            lock.withLock { storage }
        }
    }

    /// Holds the worker inside its first file operation while leaving mailbox admission available.
    /// `@unchecked Sendable`: semaphores provide the test gate; `backing` is touched only by the
    /// worker's serial queue.
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

        func invalidateHealth(in directory: URL) throws {
            try backing.invalidateHealth(in: directory)
        }

        func releaseOpen() {
            release.signal()
        }
    }

    /// Parks two accepted appends around a rejected Close, then parks that close's health commit.
    /// This makes it observable whether traffic accepted afterward runs before the close watermark.
    /// `@unchecked Sendable`: the lock protects counters/flags, semaphores provide the gates, and the
    /// backing writer remains confined to the worker's serial queue.
    private final class ClosePriorityWriter: SessionAuditWriting, @unchecked Sendable {
        let firstAppendEntered = DispatchSemaphore(value: 0)
        let secondAppendEntered = DispatchSemaphore(value: 0)
        let closeEntered = DispatchSemaphore(value: 0)
        private let releaseFirst = DispatchSemaphore(value: 0)
        private let releaseSecond = DispatchSemaphore(value: 0)
        private let releaseCloseCommit = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let backing = SessionAuditFileWriter()
        private var appendCount = 0
        private var laterAppendDidStart = false

        var hasStartedLaterAppend: Bool {
            lock.withLock { laterAppendDidStart }
        }

        func openSession(at directory: URL, initialHealth: Data) throws {
            try backing.openSession(at: directory, initialHealth: initialHealth)
        }

        func append(_ data: Data, filename: String, in directory: URL) throws {
            let index = lock.withLock {
                appendCount += 1
                if appendCount > 2 { laterAppendDidStart = true }
                return appendCount
            }
            if index == 1 {
                firstAppendEntered.signal()
                releaseFirst.wait()
            } else if index == 2 {
                secondAppendEntered.signal()
                releaseSecond.wait()
            }
            try backing.append(data, filename: filename, in: directory)
        }

        func replaceHealth(
            _ data: Data,
            in directory: URL,
            shouldCommit: @Sendable () -> Bool
        ) throws -> Bool {
            closeEntered.signal()
            releaseCloseCommit.wait()
            return try backing.replaceHealth(data, in: directory, shouldCommit: shouldCommit)
        }

        func invalidateHealth(in directory: URL) throws {
            try backing.invalidateHealth(in: directory)
        }

        func releaseFirstAppend() { releaseFirst.signal() }
        func releaseSecondAppend() { releaseSecond.signal() }
        func releaseClose() { releaseCloseCommit.signal() }
    }

    /// Opens normally, then fails the first append. A correct session stops calling it afterward.
    /// `@unchecked Sendable`: `lock` protects the append count and the backing writer is confined to
    /// the worker's serial queue.
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

        func invalidateHealth(in directory: URL) throws {
            try backing.invalidateHealth(in: directory)
        }
    }

    /// Fails before either JSONL file exists, but still permits the close marker to be installed.
    /// `@unchecked Sendable`: configuration is immutable, the semaphore is thread-safe, and the
    /// backing writer is confined to the worker's serial queue.
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

        func invalidateHealth(in directory: URL) throws {
            try backing.invalidateHealth(in: directory)
        }
    }

    /// Parks the final health replacement after the worker has already snapshotted complete state.
    /// `@unchecked Sendable`: `lock` protects the block state and captured data; semaphores gate the
    /// test while the backing writer remains confined to the worker queue.
    private final class BlockingFinalHealthWriter: SessionAuditWriting, @unchecked Sendable {
        let finalHealthEntered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let backing = SessionAuditFileWriter()
        private var hasBlocked = false
        private var storedBlockedHealth: Data?
        private var storedInvalidationCount = 0

        var blockedHealth: Data? {
            lock.withLock { storedBlockedHealth }
        }

        var invalidationCount: Int {
            lock.withLock { storedInvalidationCount }
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

        func invalidateHealth(in directory: URL) throws {
            lock.withLock { storedInvalidationCount += 1 }
            try backing.invalidateHealth(in: directory)
        }

        func releaseFinalHealth() {
            release.signal()
        }
    }

    /// Leaves the initial open marker canonical by failing both partial replacement and invalidation.
    /// `@unchecked Sendable`: configuration is immutable and the backing writer remains confined to
    /// the worker's serial queue.
    private final class FailingPartialAndInvalidationWriter:
        SessionAuditWriting, @unchecked Sendable {
        enum Failure: Error { case injected }

        private let backing = SessionAuditFileWriter()

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
            let marker = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if marker?["state"] as? String == "partial" { throw Failure.injected }
            return try backing.replaceHealth(data, in: directory, shouldCommit: shouldCommit)
        }

        func invalidateHealth(in directory: URL) throws {
            throw Failure.injected
        }
    }

    /// Parks the writer's second commit check, which occurs only after the atomic rename returned.
    /// `@unchecked Sendable`: `lock` protects every mutable field; immutable failure flags and
    /// semaphores are safe across tasks, and the backing writer runs only on the worker queue.
    private final class BlockingRenamedHealthWriter: SessionAuditWriting, @unchecked Sendable {
        enum Failure: Error { case injected }

        let completeMarkerRenamed = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let backing = SessionAuditFileWriter()
        private let failsCorrection: Bool
        private let failsInvalidation: Bool
        private var checkCount = 0
        private var hasBlocked = false
        private var didFailCorrection = false

        init(failsCorrection: Bool = false, failsInvalidation: Bool = false) {
            self.failsCorrection = failsCorrection
            self.failsInvalidation = failsInvalidation
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
            let shouldFail = lock.withLock {
                guard failsCorrection, hasBlocked, !didFailCorrection else { return false }
                didFailCorrection = true
                return true
            }
            if shouldFail { throw Failure.injected }

            return try backing.replaceHealth(data, in: directory) { [self] in
                let shouldBlock = lock.withLock {
                    checkCount += 1
                    guard checkCount == 2, !hasBlocked else { return false }
                    hasBlocked = true
                    return true
                }
                if shouldBlock {
                    completeMarkerRenamed.signal()
                    release.wait()
                }
                return shouldCommit()
            }
        }

        func invalidateHealth(in directory: URL) throws {
            if failsInvalidation { throw Failure.injected }
            try backing.invalidateHealth(in: directory)
        }

        func releaseRenamedHealth() {
            release.signal()
        }
    }

    /// Parks the first marker invalidation after a session has already finalized complete.
    /// `@unchecked Sendable`: `lock` protects the one-shot block flag; semaphores provide the test
    /// gate, and the backing writer is confined to the worker's serial queue.
    private final class BlockingInvalidationWriter: SessionAuditWriting, @unchecked Sendable {
        let invalidationEntered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let backing = SessionAuditFileWriter()
        private var hasBlocked = false

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
            try backing.replaceHealth(data, in: directory, shouldCommit: shouldCommit)
        }

        func invalidateHealth(in directory: URL) throws {
            let shouldBlock = lock.withLock {
                guard !hasBlocked else { return false }
                hasBlocked = true
                return true
            }
            if shouldBlock {
                invalidationEntered.signal()
                release.wait()
            }
            try backing.invalidateHealth(in: directory)
        }

        func releaseInvalidation() {
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

    @Test func rejectedCloseRunsAfterItsPredecessorsButBeforeLaterSessionTraffic() async throws {
        let stoppedDirectory = ActivityLogTests.tmp()
        let replacementDirectory = ActivityLogTests.tmp()
        defer {
            try? FileManager.default.removeItem(at: stoppedDirectory)
            try? FileManager.default.removeItem(at: replacementDirectory)
        }
        let writer = ClosePriorityWriter()
        let worker = SessionAuditWorker(
            limits: .init(maxEventCount: 2, maxRetainedBytes: 4_096),
            writer: writer)
        let stopped = worker.openSession(at: stoppedDirectory)
        let replacement = worker.openSession(at: replacementDirectory)
        await waitUntilIdle(worker)
        let event = BrainTrafficAuditEvent(
            tag: "coach",
            request: Data("{}".utf8),
            response: nil,
            status: nil,
            latencyMs: 1,
            error: nil,
            phases: nil,
            kind: .providerCall,
            requestContext: nil,
            date: Date())

        worker.record(event, for: stopped)
        await wait(for: writer.firstAppendEntered)
        worker.record(event, for: stopped)
        stopped.seal()
        let closeCompleted = DispatchSemaphore(value: 0)
        #expect(worker.close(
            stopped,
            deadline: ContinuousClock.now.advanced(by: .seconds(30))) { _ in
                closeCompleted.signal()
            } == .deferred)
        let retainedClose = worker.retainedSnapshot()
        #expect(retainedClose.deferredCloseCount == 1)
        #expect(retainedClose.deferredCloseApproximateBytes == 256)

        writer.releaseFirstAppend()
        await wait(for: writer.secondAppendEntered)
        worker.record(event, for: replacement)
        writer.releaseSecondAppend()

        await wait(for: writer.closeEntered)
        #expect(!writer.hasStartedLaterAppend)
        writer.releaseClose()
        await wait(for: closeCompleted)
        await waitUntilIdle(worker)
        #expect(try healthMarker(in: stoppedDirectory)["state"] as? String == "partial")
        #expect(stopped.health.snapshot.queueOverflow > 0)
        #expect(stopped.health.snapshot.closeTimeout > 0)
    }

    @Test func rejectedClosesWithoutPendingSessionWorkDoNotAccumulate() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BlockingWriter()
        let limits = SessionAuditWorker.Limits(
            maxEventCount: 1,
            maxRetainedBytes: 4_096)
        let worker = SessionAuditWorker(limits: limits, writer: writer)
        let blocked = FileSessionAudit(
            directory: directory.appendingPathComponent("blocked"),
            worker: worker)
        await wait(for: writer.openEntered)

        for index in 0..<100 {
            let audit = FileSessionAudit(
                directory: directory.appendingPathComponent("replacement-\(index)"),
                worker: worker)
            #expect(await audit.close(deadline: .zero) == .partial)
            #expect(audit.isPersistenceSettled)
            let retained = worker.retainedSnapshot()
            #expect(retained.deferredCloseCount == 0)
            #expect(retained.deferredCloseApproximateBytes == 0)
        }

        writer.releaseOpen()
        await waitUntilIdle(worker)
        _ = await blocked.close(deadline: .seconds(5))
        await blocked.waitForPersistenceToStop()
    }

    @Test func closeTimeoutReturnsWithoutReleasingBlockedDiskAndLeavesPartialMarker() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BlockingWriter()
        let worker = SessionAuditWorker(
            limits: .init(maxEventCount: 1, maxRetainedBytes: 4_096),
            writer: writer)
        let audit = FileSessionAudit(directory: directory, worker: worker)
        await wait(for: writer.openEntered)

        #expect(await audit.close(deadline: .zero) == .partial)
        #expect(audit.healthSnapshot.closeTimeout > 0)

        let settlement = Task { await audit.waitForPersistenceToStop() }
        writer.releaseOpen()
        await settlement.value
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

    @Test func partialFinalizationSatisfiesQueuedLateCorrectionWithoutDeletingMarker() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BlockingFinalHealthWriter()
        let worker = SessionAuditWorker(limits: .production, writer: writer)
        let audit = FileSessionAudit(directory: directory, worker: worker)
        await waitUntilIdle(worker)

        let close = Task { await audit.close(deadline: .seconds(5)) }
        await wait(for: writer.finalHealthEntered)
        audit.record(
            tag: "late-coach",
            request: Data("{}".utf8),
            response: nil,
            status: nil,
            latencyMs: 1)
        #expect(!audit.isPersistenceSettled)

        writer.releaseFinalHealth()
        #expect(await close.value == .partial)
        await audit.waitForPersistenceToStop()
        await waitUntilIdle(worker)

        let marker = try healthMarker(in: directory)
        #expect(marker["state"] as? String == "partial")
        #expect(marker["late_event"] as? Int == 1)
        #expect(writer.invalidationCount == 0)
    }

    @Test func finalHealthRenameCrossingDeadlineIsCorrectedToPartial() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BlockingRenamedHealthWriter()
        let worker = SessionAuditWorker(limits: .production, writer: writer)
        let audit = FileSessionAudit(directory: directory, worker: worker)
        await waitUntilIdle(worker)

        let close = Task { await audit.close(deadline: .milliseconds(20)) }
        await wait(for: writer.completeMarkerRenamed)
        #expect(await close.value == .partial)
        let settlementStarted = DispatchSemaphore(value: 0)
        let settlementFinished = CompletionFlag()
        let settlement = Task.detached {
            settlementStarted.signal()
            await audit.waitForPersistenceToStop()
            settlementFinished.mark()
        }
        await wait(for: settlementStarted)
        await Task.yield()
        #expect(!settlementFinished.isMarked)
        writer.releaseRenamedHealth()
        await settlement.value
        #expect(settlementFinished.isMarked)
        await waitUntilIdle(worker)
        let marker = try healthMarker(in: directory)
        #expect(marker["state"] as? String == "partial")
        #expect((marker["close_timeout"] as? Int ?? 0) > 0)
    }

    @Test func failedCorrectiveHealthWriteInvalidatesRejectedCompleteMarker() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BlockingRenamedHealthWriter(failsCorrection: true)
        let worker = SessionAuditWorker(limits: .production, writer: writer)
        let session = worker.openSession(at: directory)
        await waitUntilIdle(worker)
        worker.record(BrainTrafficAuditEvent(
            tag: "coach",
            request: Data("{}".utf8),
            response: nil,
            status: nil,
            latencyMs: 1,
            error: nil,
            phases: nil,
            kind: .providerCall,
            requestContext: nil,
            date: Date()), for: session)
        await waitUntilIdle(worker)
        session.seal()
        let completion = CompletionFlag()
        #expect(worker.close(
            session,
            deadline: ContinuousClock.now.advanced(by: .seconds(30))) { _ in
                completion.mark()
            } == .enqueued)
        await wait(for: writer.completeMarkerRenamed)
        session.health.markCloseTimeout()
        writer.releaseRenamedHealth()
        await waitUntilIdle(worker)

        #expect(completion.isMarked)
        let healthURL = directory.appendingPathComponent(FileSessionAudit.healthFilename)
        #expect(!FileManager.default.fileExists(atPath: healthURL.path))
        #expect(session.health.snapshot.writeFailure > 0)
        let traffic = try String(
            contentsOf: directory.appendingPathComponent(FileSessionAudit.brainTrafficFilename),
            encoding: .utf8)
        #expect(SessionAuditEvidence.assess(
            trafficJSONL: traffic,
            attemptsJSONL: "",
            healthJSON: nil).isPartial)
    }

    @Test func failedHealthInvalidationWithholdsSettlement() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BlockingRenamedHealthWriter(
            failsCorrection: true,
            failsInvalidation: true)
        let worker = SessionAuditWorker(limits: .production, writer: writer)
        let session = worker.openSession(at: directory)
        await waitUntilIdle(worker)
        session.seal()
        let completion = CompletionFlag()
        #expect(worker.close(
            session,
            deadline: ContinuousClock.now.advanced(by: .seconds(30))) { _ in
                completion.mark()
            } == .enqueued)

        await wait(for: writer.completeMarkerRenamed)
        session.health.markCloseTimeout()
        writer.releaseRenamedHealth()
        await waitUntilIdle(worker)

        #expect(!completion.isMarked)
        let marker = try healthMarker(in: directory)
        #expect(marker["state"] as? String == "complete")
    }

    @Test func failedPartialWriteAndInvalidationSettleAKnownOpenMarker() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FailingPartialAndInvalidationWriter()
        let worker = SessionAuditWorker(limits: .production, writer: writer)
        let session = worker.openSession(at: directory)
        await waitUntilIdle(worker)
        session.health.markQueueOverflow()
        session.seal()
        let completion = CompletionFlag()

        #expect(worker.close(
            session,
            deadline: ContinuousClock.now.advanced(by: .seconds(30))) { _ in
                completion.mark()
            } == .enqueued)
        await waitUntilIdle(worker)

        #expect(completion.isMarked)
        let marker = try healthMarker(in: directory)
        #expect(marker["state"] as? String == "open")
        #expect(marker["closed"] as? Bool == false)
        #expect(session.health.snapshot.writeFailure == 2)
    }

    @Test func eventAfterCompleteMakesOnlyThatSessionUnavailableUntilMarkerIsInvalidated() async throws {
        let directory = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BlockingInvalidationWriter()
        let worker = SessionAuditWorker(limits: .production, writer: writer)
        let audit = FileSessionAudit(directory: directory, worker: worker)
        await waitUntilIdle(worker)

        #expect(await audit.close(deadline: .seconds(5)) == .complete)
        #expect(audit.isPersistenceSettled)
        #expect(try healthMarker(in: directory)["state"] as? String == "complete")

        audit.record(
            tag: "late-coach",
            request: Data("{}".utf8),
            response: nil,
            status: nil,
            latencyMs: 1)
        await wait(for: writer.invalidationEntered)

        #expect(!audit.isPersistenceSettled)
        #expect(audit.healthSnapshot.lateEvent == 1)
        // The old marker may remain on disk while invalidation is parked, so the in-memory gate is
        // the protection that prevents the evaluator from accepting stale complete evidence.
        #expect(try healthMarker(in: directory)["state"] as? String == "complete")

        writer.releaseInvalidation()
        await audit.waitForPersistenceToStop()
        #expect(audit.isPersistenceSettled)
        let healthURL = directory.appendingPathComponent(FileSessionAudit.healthFilename)
        #expect(!FileManager.default.fileExists(atPath: healthURL.path))
    }

    @Test func lateMarkerCorrectionsStayBoundedWhileInvalidationIsBlocked() async throws {
        let base = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let writer = BlockingInvalidationWriter()
        let limits = SessionAuditWorker.Limits(
            maxEventCount: 1,
            maxRetainedBytes: 4_096)
        let worker = SessionAuditWorker(limits: limits, writer: writer)
        var audits: [FileSessionAudit] = []

        for index in 0..<20 {
            let directory = base.appendingPathComponent("session-\(index)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false)
            let audit = FileSessionAudit(directory: directory, worker: worker)
            await waitUntilIdle(worker)
            #expect(await audit.close(deadline: .seconds(5)) == .complete)
            audits.append(audit)
        }

        audits[0].record(
            tag: "late-coach",
            request: Data("{}".utf8),
            response: nil,
            status: nil,
            latencyMs: 1)
        await wait(for: writer.invalidationEntered)
        for audit in audits.dropFirst() {
            audit.record(
                tag: "late-coach",
                request: Data("{}".utf8),
                response: nil,
                status: nil,
                latencyMs: 1)
        }

        let retained = worker.retainedSnapshot()
        #expect(retained.lateCorrectionCount == limits.maxEventCount)
        #expect(retained.lateCorrectionApproximateBytes == 256)
        #expect(audits.dropFirst().allSatisfy { !$0.isPersistenceSettled })

        writer.releaseInvalidation()
        await audits[0].waitForPersistenceToStop()
        await waitUntilIdle(worker)
        #expect(worker.retainedSnapshot().lateCorrectionCount == 0)
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
        await waitUntilIdle(worker)
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
