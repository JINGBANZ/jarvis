import Testing
@testable import JarvisCore

@Suite struct SpeechActivityGateTests {
    @Test func interruptionBeforeWaitRegistrationIsSticky() async {
        let gate = SpeechActivityGate()
        gate.setActive(true, for: .me)
        let generation = gate.interruptGenerationSnapshot()

        // Models a manual hint landing after CoachDriver's pending-trigger snapshot but before
        // SpeechActivityGate has installed the continuation.
        gate.interruptWaiters()

        #expect(await completesBeforeTimeout {
            await gate.waitUntilInactive(unlessInterruptedAfter: generation)
        })
    }

    @Test func interruptionResumesARegisteredWaitWithoutChangingActivity() async {
        let gate = SpeechActivityGate()
        gate.setActive(true, for: .them)
        let generation = gate.interruptGenerationSnapshot()
        let interrupter = Task {
            await Task.yield()
            gate.interruptWaiters()
        }

        #expect(await completesBeforeTimeout {
            await gate.waitUntilInactive(unlessInterruptedAfter: generation)
        })
        await interrupter.value

        // The interruption wakes only the explicit hint. A later automatic wait still sees the
        // speaker as active and therefore remains parked until ordinary speech inactivity.
        let laterGeneration = gate.interruptGenerationSnapshot()
        #expect(!(await completesBeforeTimeout(nanoseconds: 20_000_000) {
            await gate.waitUntilInactive(unlessInterruptedAfter: laterGeneration)
        }))
        gate.setActive(false, for: .them)
        await gate.waitUntilInactive(unlessInterruptedAfter: laterGeneration)
    }
}

private func completesBeforeTimeout(
    nanoseconds: UInt64 = 200_000_000,
    _ operation: @escaping @Sendable () async -> Void
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await operation()
            return true
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: nanoseconds)
            return false
        }
        let completed = await group.next() ?? false
        group.cancelAll()
        return completed
    }
}
