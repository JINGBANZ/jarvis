import Testing
@testable import JarvisCore

@Suite struct TerminalActionDeliveryTests {
    @MainActor
    private final class Probe {
        var events: [ActivityLog.EventKind] = []
        var rendered: [[String]] = []
        var ended = 0

        func record(_ event: ActivityLog.Event) {
            switch event {
            case .tip:
                events.append(.tip)
            case .stayedSilent:
                events.append(.stayedSilent)
            default:
                Issue.record("unexpected terminal event")
            }
        }
    }

    @MainActor @Test
    func invalidatedSessionCannotDeliverWhileReplacementCan() {
        let oldProbe = Probe()
        let old = TerminalActionDelivery(
            recordActivity: { oldProbe.record($0) },
            renderOverlay: { lines, _ in oldProbe.rendered.append(lines) },
            endSession: { oldProbe.ended += 1 })
        old.invalidate()

        #expect(!old.deliver(
            .speak(callID: "old", lines: ["old tip"]),
            perLineSeconds: [1]))
        #expect(oldProbe.events.isEmpty)
        #expect(oldProbe.rendered.isEmpty)
        #expect(oldProbe.ended == 1)

        let newProbe = Probe()
        let replacement = TerminalActionDelivery(
            recordActivity: { newProbe.record($0) },
            renderOverlay: { lines, _ in newProbe.rendered.append(lines) })

        #expect(replacement.deliver(
            .speak(callID: "new", lines: ["new tip"]),
            perLineSeconds: [1]))
        #expect(newProbe.events == [.tip])
        #expect(newProbe.rendered == [["new tip"]])
    }

    @MainActor @Test
    func invalidationIsIdempotentAndSuppressesSilence() {
        let probe = Probe()
        let delivery = TerminalActionDelivery(
            recordActivity: { probe.record($0) },
            renderOverlay: { _, _ in },
            endSession: { probe.ended += 1 })

        delivery.invalidate()
        delivery.invalidate()

        #expect(!delivery.deliver(.staySilent(callID: "late")))
        #expect(probe.events.isEmpty)
        #expect(probe.ended == 1)
    }
}
