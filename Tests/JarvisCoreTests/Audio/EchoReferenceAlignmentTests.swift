import Testing
@testable import JarvisCore

@Suite struct EchoReferenceAlignmentTests {
    @Test func equalLengthReferencePassesThrough() {
        #expect(EchoReferenceAlignment.aligned([1, 2, 3], toFrameCount: 3) == [1, 2, 3])
    }

    @Test func shortReferenceIsPaddedOnlyInTheAECCopy() {
        let systemAudio: [Int16] = [10, 20]

        let aecReference = EchoReferenceAlignment.aligned(systemAudio, toFrameCount: 4)

        #expect(aecReference == [10, 20, 0, 0])
        #expect(systemAudio == [10, 20])
    }

    @Test func longReferenceIsTruncatedOnlyInTheAECCopy() {
        let systemAudio: [Int16] = [10, 20, 30, 40]

        let aecReference = EchoReferenceAlignment.aligned(systemAudio, toFrameCount: 2)

        #expect(aecReference == [10, 20])
        #expect(systemAudio == [10, 20, 30, 40])
    }

    @Test func emptyMicFrameProducesEmptyAECReferenceWithoutTouchingSystemAudio() {
        let systemAudio: [Int16] = [10, 20]

        #expect(EchoReferenceAlignment.aligned(systemAudio, toFrameCount: 0).isEmpty)
        #expect(systemAudio == [10, 20])
    }
}
