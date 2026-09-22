import Foundation
import Testing
@testable import JarvisCore

@Suite struct PendingSpeechWindowTests {
    @Test func recognizedSpeechReportsItsLocalOnset() throws {
        var window = PendingSpeechWindow()
        window.recordLocalSpeech(active: true, at: 9)
        window.recordRecognitionObserved(at: 9.4)

        let work = window.state(queuedSince: nil, isRecognizing: true)
        #expect(work == .pending(since: 9))
        #expect(work.permitsCoaching(through: 8))
        #expect(!work.permitsCoaching(through: 9))
        #expect(!work.permitsCoaching(through: 10))
        #expect(!work.permitsCoaching(through: nil))
    }

    @Test func theWindowSurvivesTheBufferDrainingBeforeRecognitionStarts() {
        var window = PendingSpeechWindow()
        window.recordLocalSpeech(active: true, at: 9)

        #expect(window.state(queuedSince: 9.1, isRecognizing: false) == .pending(since: 9.1))
        #expect(window.state(queuedSince: nil, isRecognizing: false) == .settled)
        #expect(window.state(queuedSince: nil, isRecognizing: true) == .pending(since: 9))
    }

    @Test func laterSpeechDoesNotMoveAnOpenWindow() {
        var window = PendingSpeechWindow()
        window.recordLocalSpeech(active: true, at: 9)
        window.recordLocalSpeech(active: false, at: 10)
        window.recordLocalSpeech(active: true, at: 11)

        #expect(window.state(queuedSince: nil, isRecognizing: true) == .pending(since: 9))
    }

    @Test func aClosedWindowOpensAtTheNextOnset() {
        var window = PendingSpeechWindow()
        window.recordLocalSpeech(active: true, at: 9)
        _ = window.state(queuedSince: nil, isRecognizing: true)
        window.recordLocalSpeech(active: false, at: 10)
        #expect(window.state(queuedSince: nil, isRecognizing: false) == .settled)

        window.recordLocalSpeech(active: true, at: 14)
        #expect(window.state(queuedSince: nil, isRecognizing: true) == .pending(since: 14))
    }

    @Test func recognitionThatOutrunsTheLocalDetectorCapsTheStart() {
        var window = PendingSpeechWindow()
        window.recordRecognitionObserved(at: 12)
        window.recordRecognitionObserved(at: 12.5)
        window.recordLocalSpeech(active: true, at: 13)

        #expect(window.state(queuedSince: nil, isRecognizing: true) == .pending(since: 12))
    }

    @Test func recognizedSpeechTheDetectorMissedStaysUnknown() {
        var window = PendingSpeechWindow()
        window.recordRecognitionObserved(at: 12)

        let work = window.state(queuedSince: 14, isRecognizing: true)
        #expect(work == .pending(since: nil))
        #expect(!work.permitsCoaching(through: 1))
    }

    @Test func queuedAudioOlderThanTheUtteranceWins() {
        var window = PendingSpeechWindow()
        window.recordLocalSpeech(active: true, at: 9)

        #expect(window.state(queuedSince: 8, isRecognizing: true) == .pending(since: 8))
        #expect(window.state(queuedSince: 10, isRecognizing: true) == .pending(since: 9))
    }

    @Test func anUntimedOnsetLeavesRecognizedSpeechUnknown() {
        var window = PendingSpeechWindow()
        window.recordLocalSpeech(active: true, at: .infinity)

        #expect(window.state(queuedSince: nil, isRecognizing: true) == .pending(since: nil))
    }

    @Test func resetClosesAnOpenWindow() {
        var window = PendingSpeechWindow()
        window.recordLocalSpeech(active: true, at: 9)
        window.reset()

        #expect(window.state(queuedSince: nil, isRecognizing: true) == .pending(since: nil))
        #expect(window.state(queuedSince: nil, isRecognizing: false) == .settled)
    }
}
