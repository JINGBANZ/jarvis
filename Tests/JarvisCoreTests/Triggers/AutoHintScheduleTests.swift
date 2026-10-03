import Testing
@testable import JarvisCore

@Suite struct AutoHintScheduleTests {
    @Test func waitsTenSecondsAndDoesNotCatchUpMissedTicks() {
        var schedule = AutoHintSchedule()
        #expect((schedule.takeTick(at: 100)) == false)
        schedule.setActive(true, at: 100)
        #expect((schedule.takeTick(at: 109.9)) == false)
        #expect((schedule.takeTick(at: 110)) == true)
        #expect((schedule.takeTick(at: 110)) == false)
        #expect((schedule.takeTick(at: 145)) == true)
        #expect((schedule.takeTick(at: 145)) == false)
        #expect((schedule.takeTick(at: 154.9)) == false)
        #expect((schedule.takeTick(at: 155)) == true)
    }

    @Test func disablingOrStoppingDisarmsAndRestartWaitsForANewInterval() {
        var schedule = AutoHintSchedule()
        schedule.setActive(true, at: 0)
        schedule.setActive(false, at: 9)
        #expect((schedule.takeTick(at: 100)) == false)
        schedule.setActive(true, at: 100)
        #expect((schedule.takeTick(at: 109)) == false)
        #expect((schedule.takeTick(at: 110)) == true)
    }
}
