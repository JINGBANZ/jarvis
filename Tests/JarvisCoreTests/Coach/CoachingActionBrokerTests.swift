import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoachingActionBrokerTests {
    /// `@unchecked Sendable` is safe because `lock` guards the only mutable state.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }
    }

    private func broker(
        capture: ScreenSnapshot? = nil,
        requiredTerminalToolName: String? = nil
    ) -> CoachingActionBroker {
        CoachingActionBroker(
            identity: .init(configurationRevision: 7),
            capture: { capture },
            requiredTerminalToolName: requiredTerminalToolName)
    }

    private func failure(
        _ operation: () async throws -> Void
    ) async -> CoachingActionBroker.Failure? {
        do {
            try await operation()
            return nil
        } catch let error as CoachingActionBroker.Failure {
            return error
        } catch {
            Issue.record("unexpected error: \(error)")
            return nil
        }
    }

    @Test func oneCaptureThenOneTerminalCommit() async throws {
        let shot = ScreenSnapshot(
            imageBase64: Data("jpeg".utf8).base64EncodedString(),
            recognizedText: "let answer = 42")
        let broker = broker(capture: shot)

        #expect(try await broker.call(
            requestID: "capture-1",
            name: captureScreenTool.name,
            argumentsJSON: "{}") == .capture(shot))
        #expect(try await broker.acknowledgeCaptureDelivery(requestID: "capture-1"))
        #expect(try await broker.call(
            requestID: "terminal",
            name: speakTool.name,
            argumentsJSON: #"{"lines":["Use a map.","State the invariant."]}"#) == .terminalAccepted)

        #expect(try await broker.requireTerminal()
                == .speak(callID: "terminal", lines: ["Use a map.", "State the invariant."]))
        #expect(try await broker.commit()
                == .speak(callID: "terminal", lines: ["Use a map.", "State the invariant."]))
        #expect(await broker.captureObservation()
                == .init(callID: "capture-1", snapshot: shot))
    }

    @Test func captureIsObservedOnlyAfterDeliveryAcknowledgement() async throws {
        let observer = Counter()
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 1),
            capture: { nil },
            captureObserver: { _ in observer.increment() })

        _ = try await broker.call(
            requestID: "capture",
            name: captureScreenTool.name,
            argumentsJSON: "{}")
        #expect(observer.value == 0)
        #expect(await broker.captureObservation() == nil)

        #expect(try await broker.acknowledgeCaptureDelivery(requestID: "capture"))
        #expect(try await broker.acknowledgeCaptureDelivery(requestID: "capture"))
        #expect(observer.value == 1)
        #expect(await broker.captureObservation()
                == .init(callID: "capture", snapshot: nil))

        let racedTerminal = CoachingActionBroker(
            identity: .init(configurationRevision: 2),
            capture: { nil },
            captureObserver: { _ in observer.increment() })
        _ = try await racedTerminal.call(
            requestID: "capture-race",
            name: captureScreenTool.name,
            argumentsJSON: "{}")
        #expect(await failure {
            _ = try await racedTerminal.call(
                requestID: "speak-race",
                name: speakTool.name,
                argumentsJSON: #"{"lines":["I did not receive the capture."]}"#)
        } == .concurrentCall)
        #expect(await racedTerminal.captureObservation() == nil)
    }

    @Test func failedCaptureStillConsumesTheSingleCaptureOpportunity() async throws {
        let counter = Counter()
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 1),
            capture: {
                counter.increment()
                return nil
            })

        _ = try await broker.call(
            requestID: "first",
            name: captureScreenTool.name,
            argumentsJSON: "{}")

        let duplicate = await failure {
            _ = try await broker.call(
                requestID: "second",
                name: captureScreenTool.name,
                argumentsJSON: "{}")
        }
        #expect(duplicate == .duplicateCapture)
        #expect(counter.value == 1)
    }

    @Test func malformedUnknownAndMissingTerminalAreTypedFailures() async {
        let malformed = broker()
        #expect(await failure {
            _ = try await malformed.call(
                requestID: "bad",
                name: speakTool.name,
                argumentsJSON: #"{"line":"missing plural"}"#)
        } == .malformedArguments(speakTool.name))
        #expect(await failure {
            _ = try await malformed.call(
                requestID: "retry",
                name: speakTool.name,
                argumentsJSON: #"{"lines":["A retry must not revive the attempt."]}"#)
        } == .malformedArguments(speakTool.name))

        let unknown = broker()
        #expect(await failure {
            _ = try await unknown.call(
                requestID: "unknown",
                name: "open_url",
                argumentsJSON: "{}")
        } == .unknownTool("open_url"))

        let missing = broker()
        #expect(await failure {
            _ = try await missing.requireTerminal()
        } == .missingTerminal)
    }

    @Test func brokerRejectsKnownToolsNotAllowedForTheAttempt() async {
        let manualHint = CoachingActionBroker(
            identity: .init(configurationRevision: 7),
            capture: {
                Issue.record("an unlisted capture reached the host")
                return nil
            },
            allowedToolNames: [speakTool.name],
            requiredTerminalToolName: speakTool.name)

        #expect(await failure {
            _ = try await manualHint.call(
                requestID: "capture",
                name: captureScreenTool.name,
                argumentsJSON: "{}")
        } == .toolNotAllowed(captureScreenTool.name))
    }

    @Test func terminalExclusivityAndOrderingAreEnforced() async throws {
        let duplicate = broker()
        _ = try await duplicate.call(
            requestID: "speak",
            name: speakTool.name,
            argumentsJSON: #"{"lines":["One."]}"#)
        #expect(await failure {
            _ = try await duplicate.call(
                requestID: "silent",
                name: staySilentTool.name,
                argumentsJSON: "{}")
        } == .duplicateTerminal)

        let afterTerminal = broker()
        _ = try await afterTerminal.call(
            requestID: "silent",
            name: staySilentTool.name,
            argumentsJSON: "{}")
        #expect(await failure {
            _ = try await afterTerminal.call(
                requestID: "capture",
                name: captureScreenTool.name,
                argumentsJSON: "{}")
        } == .captureAfterTerminal)

        let multiple = broker()
        #expect(await failure {
            try await multiple.rejectMultipleCallsInResponse()
        } == .multipleCallsInResponse)

        let mismatched = broker()
        #expect(await failure {
            try await mismatched.rejectReturnedCallMismatch()
        } == .returnedCallMismatch)
    }

    @Test func forcedTerminalIsEnforced() async throws {
        let forced = broker(requiredTerminalToolName: speakTool.name)
        #expect(await failure {
            _ = try await forced.call(
                requestID: "silent",
                name: staySilentTool.name,
                argumentsJSON: "{}")
        } == .forcedTerminalMismatch(
            expected: speakTool.name,
            actual: staySilentTool.name))
    }

    @Test func speakRequiresAtLeastOneNonblankLine() async throws {
        let empty = broker()
        #expect(await failure {
            _ = try await empty.call(
                requestID: "empty",
                name: speakTool.name,
                argumentsJSON: #"{"lines":[" ","\n"]}"#)
        } == .malformedArguments(speakTool.name))

        let filtered = broker()
        _ = try await filtered.call(
            requestID: "speak",
            name: speakTool.name,
            argumentsJSON: #"{"lines":[" ","Keep the invariant."]}"#)
        #expect(try await filtered.commit()
                == .speak(callID: "speak", lines: ["Keep the invariant."]))
    }

    @Test func invalidatedAttemptsCannotStageActions() async {
        let invalidated = broker()
        invalidated.invalidate()
        #expect(await failure {
            _ = try await invalidated.call(
                requestID: "silent",
                name: staySilentTool.name,
                argumentsJSON: "{}")
        } == .invalidated)
    }

    @Test func commitIsExactlyOnce() async throws {
        let broker = broker()
        _ = try await broker.call(
            requestID: "silent",
            name: staySilentTool.name,
            argumentsJSON: "{}")
        _ = try await broker.commit()
        #expect(await failure {
            _ = try await broker.commit()
        } == .duplicateCommit)
    }
}
