import CoreGraphics

@main
struct TestDisplayLayoutFixture {
    static func main() {
        typealias Screen = TestDisplayLayout.Screen
        let physical = Screen(id: 1, model: 42, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), mirrored: false)
        let placeholder = Screen(id: 2, model: 0x76697274, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), mirrored: false)
        let test = Screen(id: 3, model: 21587, frame: CGRect(x: 2560, y: 0, width: 1920, height: 1080), mirrored: false)
        let primaryTest = Screen(id: 3, model: 21587, frame: placeholder.frame, mirrored: false)
        let empty = TestDisplayLayout(screens: [], main: 0)
        let headless = TestDisplayLayout(screens: [placeholder], main: 2)
        let desktop = TestDisplayLayout(screens: [physical], main: 1)
        let headlessTest = TestDisplayLayout(screens: [primaryTest], main: 3)
        let extended = TestDisplayLayout(screens: [physical, test], main: 1)

        precondition(empty.accepts(headlessTest, display: 3), "empty headless desktop must admit the test display")
        precondition(headless.accepts(headlessTest, display: 3), "placeholder may yield to the shared primary display")
        precondition(headless.accepts(TestDisplayLayout(screens: [placeholder, primaryTest], main: 3), display: 3),
                     "a synthetic placeholder may remain while tests run")
        precondition(headlessTest.usable(display: 3, width: 1920, height: 1080), "existing headless test display must be reusable")
        precondition(headlessTest.matches(headlessTest), "command completion must retain the shared display")
        precondition(!headlessTest.matches(empty), "display disappearance during tests must fail")
        precondition(!headless.accepts(extended, display: 3), "a newly attached physical monitor needs fresh admission")
        precondition(!headlessTest.matches(desktop), "command completion must not silently adopt a physical monitor")
        precondition(desktop.accepts(extended, display: 3), "physical desktop may gain a disjoint test display")
        precondition(!desktop.accepts(TestDisplayLayout(screens: [physical, test], main: 3), display: 3),
                     "physical main display must be preserved")
        precondition(!desktop.accepts(TestDisplayLayout(screens: [physical, primaryTest], main: 1), display: 3),
                     "test display must not overlap a physical screen")
        precondition(!desktop.accepts(headlessTest, display: 3), "physical screen disappearance must fail")
        precondition(extended.matches(extended), "shared display and physical desktop must remain at completion")
        precondition(!extended.matches(desktop), "removing the shared display must fail completion")
        let moved = Screen(id: 1, model: 42, frame: CGRect(x: 10, y: 0, width: 2560, height: 1440), mirrored: false)
        precondition(!extended.matches(TestDisplayLayout(screens: [moved, test], main: 1)),
                     "physical screen movement must fail completion")
        let mirrored = Screen(id: 3, model: 21587, frame: placeholder.frame, mirrored: true)
        precondition(!headless.accepts(TestDisplayLayout(screens: [mirrored], main: 3), display: 3),
                     "headless mode must not admit a mirrored test display")
        print("Display layout: 16 headless and physical preservation checks passed")
    }
}
