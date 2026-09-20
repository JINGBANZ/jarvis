import Testing
@testable import JarvisCore

// Bound a missing wakeup with the test timeout; a short task race measures CI scheduling latency.
@Suite(.timeLimit(.minutes(1))) struct TranscriptionSettlementGateTests {
    @Test func interruptionBeforeWaitRegistrationIsSticky() async {
        let gate = TranscriptionSettlementGate()
        gate.update(.pending(since: nil), for: .me)
        let generation = gate.interruptGenerationSnapshot()

        // Interrupts after the generation snapshot but before the wait registers its continuation.
        gate.interruptWaiters()

        await gate.waitUntilSettled(unlessInterruptedAfter: generation)
    }

    @Test func interruptionResumesARegisteredWaitWithoutChangingProviderState() async {
        let gate = TranscriptionSettlementGate()
        gate.update(.pending(since: nil), for: .them)
        let generation = gate.interruptGenerationSnapshot()
        let interrupter = Task {
            await Task.yield()
            gate.interruptWaiters()
        }

        await gate.waitUntilSettled(unlessInterruptedAfter: generation)
        await interrupter.value

        let laterGeneration = gate.interruptGenerationSnapshot()
        #expect(!(await completesBeforeTimeout(nanoseconds: 20_000_000) {
            await gate.waitUntilSettled(unlessInterruptedAfter: laterGeneration)
        }))
        gate.update(.settled, for: .them)
        await gate.waitUntilSettled(unlessInterruptedAfter: laterGeneration)
    }
}

private func completesBeforeTimeout(
    nanoseconds: UInt64,
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
