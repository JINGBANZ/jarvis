import Testing
@testable import JarvisCore

// `#expect` cannot call a mutating method on its operand, so every `schedule` result is taken into a
// local before it is asserted.
@Suite("Live e2e audio timeline")
struct AudioTimelineTests {
    private static let silence = [Int16](repeating: 0, count: AudioTimeline.chunkSampleCount)

    @Test("silence-only ticks emit full zero chunks with per-stream sequences, microphone first")
    func silenceOnly() {
        var timeline = AudioTimeline(liveStreams: [.microphone, .system])

        for expectedSequence in UInt64(1)...3 {
            let chunks = timeline.tick()
            #expect(chunks.map(\.stream) == [.microphone, .system])
            for chunk in chunks {
                #expect(chunk.sequence == expectedSequence)
                #expect(chunk.samples == Self.silence)
                #expect(!chunk.clipStarted)
                #expect(!chunk.clipEnded)
            }
        }
        #expect(timeline.isIdle)
    }

    @Test("a delayed clip starts in the right chunk, ends in the chunk with its last sample, then pads")
    func delayedClip() {
        var timeline = AudioTimeline(liveStreams: [.system])
        let clip = ramp(1_000)

        let accepted = timeline.schedule(clip, on: .system, afterChunks: 2)
        #expect(accepted)
        #expect(!timeline.isIdle)

        let chunks = (0..<6).map { _ in timeline.tick()[0] }
        #expect(chunks[0].samples == Self.silence)
        #expect(chunks[1].samples == Self.silence)
        #expect(!chunks[0].clipStarted && !chunks[1].clipStarted)

        #expect(chunks[2].clipStarted)
        #expect(!chunks[2].clipEnded)
        #expect(chunks[2].samples == Array(clip[0..<480]))

        #expect(!chunks[3].clipStarted)
        #expect(!chunks[3].clipEnded)
        #expect(chunks[3].samples == Array(clip[480..<960]))

        #expect(!chunks[4].clipStarted)
        #expect(chunks[4].clipEnded)
        #expect(chunks[4].samples == Array(clip[960..<1_000]) + [Int16](repeating: 0, count: 440))

        #expect(chunks[5].samples == Self.silence)
        #expect(!chunks[5].clipStarted && !chunks[5].clipEnded)
        #expect(chunks.map(\.sequence) == [1, 2, 3, 4, 5, 6])
        #expect(timeline.isIdle)
    }

    @Test("a clip shorter than one chunk sets both edges on the same chunk")
    func shortClip() {
        var timeline = AudioTimeline(liveStreams: [.microphone])
        let clip = ramp(100)

        let accepted = timeline.schedule(clip, on: .microphone)
        #expect(accepted)
        let chunk = timeline.tick()[0]

        #expect(chunk.clipStarted)
        #expect(chunk.clipEnded)
        #expect(chunk.samples == clip + [Int16](repeating: 0, count: 380))
        #expect(timeline.isIdle)
    }

    @Test("a second clip on the same stream queues in the chunk after the first one ends")
    func queuedClip() {
        var timeline = AudioTimeline(liveStreams: [.system])
        let first = ramp(500)
        let second = ramp(10, from: 2_000)

        let accepted = [
            timeline.schedule(first, on: .system),
            timeline.schedule(second, on: .system),
        ]
        #expect(accepted == [true, true])

        let chunks = (0..<4).map { _ in timeline.tick()[0] }
        #expect(chunks[0].clipStarted && !chunks[0].clipEnded)
        #expect(!chunks[1].clipStarted && chunks[1].clipEnded)
        #expect(chunks[1].samples == Array(first[480..<500]) + [Int16](repeating: 0, count: 460))
        #expect(chunks[2].clipStarted && chunks[2].clipEnded)
        #expect(chunks[2].samples == second + [Int16](repeating: 0, count: 470))
        #expect(chunks[3].samples == Self.silence)
        #expect(timeline.isIdle)
    }

    @Test("a later requested start wins over the end of the queue")
    func requestedStartAfterQueue() {
        var timeline = AudioTimeline(liveStreams: [.microphone])

        let accepted = [
            timeline.schedule(ramp(10), on: .microphone),
            timeline.schedule(ramp(10), on: .microphone, afterChunks: 3),
        ]
        #expect(accepted == [true, true])

        let starts = (0..<5).map { _ in timeline.tick()[0].clipStarted }
        #expect(starts == [true, false, false, true, false])
    }

    @Test("overlapping clips on the two streams keep independent sequences and edges")
    func overlappingStreams() {
        var timeline = AudioTimeline(liveStreams: [.microphone, .system])
        let long = ramp(1_200)
        let short = ramp(300, from: 5_000)

        let accepted = [
            timeline.schedule(long, on: .system),
            timeline.schedule(short, on: .microphone, afterChunks: 1),
        ]
        #expect(accepted == [true, true])

        var microphone: [AudioTimeline.Chunk] = []
        var system: [AudioTimeline.Chunk] = []
        for _ in 0..<4 {
            let chunks = timeline.tick()
            #expect(chunks.map(\.stream) == [.microphone, .system])
            microphone.append(chunks[0])
            system.append(chunks[1])
        }

        #expect(microphone.map(\.sequence) == [1, 2, 3, 4])
        #expect(system.map(\.sequence) == [1, 2, 3, 4])
        #expect(microphone.map(\.clipStarted) == [false, true, false, false])
        #expect(microphone.map(\.clipEnded) == [false, true, false, false])
        #expect(microphone[1].samples == short + [Int16](repeating: 0, count: 180))
        #expect(system.map(\.clipStarted) == [true, false, false, false])
        #expect(system.map(\.clipEnded) == [false, false, true, false])
        #expect(system[2].samples == Array(long[960..<1_200]) + [Int16](repeating: 0, count: 240))
        #expect(timeline.isIdle)
    }

    @Test(
        "a single-stream timeline emits nothing on the dead stream and refuses to schedule there",
        arguments: [
            (AudioTimeline.Stream.microphone, AudioTimeline.Stream.system),
            (AudioTimeline.Stream.system, AudioTimeline.Stream.microphone),
        ])
    func deadStream(live: AudioTimeline.Stream, dead: AudioTimeline.Stream) {
        var timeline = AudioTimeline(liveStreams: [live])

        let accepted = timeline.schedule(ramp(100), on: dead)
        #expect(!accepted)
        #expect(timeline.isIdle)

        for expectedSequence in UInt64(1)...3 {
            let chunks = timeline.tick()
            #expect(chunks.map(\.stream) == [live])
            #expect(chunks.first?.sequence == expectedSequence)
            #expect(chunks.first?.clipStarted == false)
        }
    }

    @Test("an empty clip is refused")
    func emptyClip() {
        var timeline = AudioTimeline(liveStreams: [.microphone, .system])

        let accepted = timeline.schedule([], on: .microphone)
        #expect(!accepted)
        #expect(timeline.isIdle)
    }

    /// Distinct non-zero samples, so a misplaced or misordered slice cannot pass as silence or as the
    /// right audio.
    private func ramp(_ count: Int, from start: Int16 = 1) -> [Int16] {
        (0..<count).map { start + Int16($0) }
    }
}
