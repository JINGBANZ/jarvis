import Testing
@testable import JarvisCore

@Suite struct TranscriptTests {
    @Test func windowFiltersByAgeAndFormatsTimestamps() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "let me read the problem", at: 0))
        t.append(.init(speaker: .me, text: "maybe a hash map", at: 102))   // 01:42
        let rendered = t.renderWindow(seconds: 90, now: 120)
        #expect(!rendered.contains("read the problem"))
        #expect(rendered.contains("[01:42] me: maybe a hash map"))
    }

    @Test func silenceDurationFromLastLine() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "hmm", at: 50))
        #expect(abs(t.silenceDuration(now: 70) - 20) < 0.001)
    }

    @Test func silenceDurationWhenEmptyIsZero() {
        let t = RollingTranscript()
        #expect(abs(t.silenceDuration(now: 70) - 0) < 0.001)
    }
}
