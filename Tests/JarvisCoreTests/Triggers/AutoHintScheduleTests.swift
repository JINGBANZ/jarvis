import Testing
@testable import JarvisCore

@Suite struct AutoHintScheduleTests {
    @Test func waitsOneMinuteAndDoesNotCatchUpMissedTicks() {
        var schedule = AutoHintSchedule()
        #expect((schedule.takeTick(at: 100)) == false)
        schedule.setActive(true, at: 100)
        #expect((schedule.takeTick(at: 159.9)) == false)
        #expect((schedule.takeTick(at: 160)) == true)
        #expect((schedule.takeTick(at: 160)) == false)
        #expect((schedule.takeTick(at: 345)) == true)
        #expect((schedule.takeTick(at: 345)) == false)
        #expect((schedule.takeTick(at: 404.9)) == false)
        #expect((schedule.takeTick(at: 405)) == true)
    }

    @Test func disablingOrStoppingDisarmsAndRestartWaitsForANewInterval() {
        var schedule = AutoHintSchedule()
        schedule.setActive(true, at: 0)
        schedule.setActive(false, at: 59)
        #expect((schedule.takeTick(at: 100)) == false)
        schedule.setActive(true, at: 100)
        #expect((schedule.takeTick(at: 159)) == false)
        #expect((schedule.takeTick(at: 160)) == true)
    }
}
