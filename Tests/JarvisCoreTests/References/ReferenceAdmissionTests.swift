import Foundation
import Testing
@testable import JarvisCore

@Suite("Reference admission")
struct ReferenceAdmissionTests {
    @Test func changingGenerationsNeverExtendsOriginalDeadline() {
        let admission = ReferenceAdmission(startedAt: .seconds(20))
        #expect(admission.decide(now: .seconds(20), enabled: true, generation: 1,
                                 metadata: .preparing(generation: 1)) == .wait)
        #expect(admission.decide(now: .milliseconds(21_900), enabled: true, generation: 2,
                                 metadata: .ready(generation: 1, count: 3)) == .wait)
        #expect(admission.decide(now: .seconds(22), enabled: true, generation: 2,
                                 metadata: .ready(generation: 2, count: 3)) == .omit(.timeout))
        #expect(admission.deadline == .seconds(22))
    }

    @Test func onlyCurrentCompleteGenerationCanBeAdmitted() {
        let admission = ReferenceAdmission(startedAt: .zero)
        #expect(admission.decide(now: .seconds(1), enabled: true, generation: 9,
                                 metadata: .ready(generation: 9, count: 300)) == .admit(generation: 9))
        #expect(admission.decide(now: .seconds(1), enabled: true, generation: 9,
                                 metadata: .failed(generation: 8)) == .wait)
        #expect(admission.decide(now: .seconds(1), enabled: true, generation: 9,
                                 metadata: .failed(generation: 9)) == .omit(.failed))
    }

    @Test func disabledAndEmptyAreSilentButFailuresAreTyped() {
        let admission = ReferenceAdmission(startedAt: .zero)
        #expect(admission.decide(now: .seconds(5), enabled: false, generation: 3, metadata: nil) == .omit(.disabled))
        #expect(admission.decide(now: .zero, enabled: true, generation: 3,
                                 metadata: .ready(generation: 3, count: 0)) == .omit(.empty))
        #expect(ReferenceOmissionReason.disabled.warning == nil)
        #expect(ReferenceOmissionReason.empty.warning == nil)
        #expect(ReferenceOmissionReason.failed.warning != nil)
        #expect(ReferenceOmissionReason.timeout.warning != nil)
    }
}
