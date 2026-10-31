@testable import JarvisCore

extension CoachAttemptRunner {
    func runTestAttempt(_ work: PendingCoachingWork, using attempt: CoachDriver.AttemptBrain) async -> AttemptExecution {
        let scope = CoachAttemptScope()
        let execution = await withTaskCancellationHandler {
            await runAttempt(work, using: attempt, scope: scope)
        } onCancel: {
            scope.cancel()
        }
        await scope.finish().value
        return execution
    }
}
