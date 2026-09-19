import Foundation
import Testing
@testable import JarvisCore

@Suite struct MouseHotkeyTests {
    @Test func mouseBindingPersistsAlongsideKeyboardAndClearsIndependently() {
        let defaults = UserDefaults(suiteName: "MouseHotkeyTests.\(UUID().uuidString)")!
        let preference = HotkeyPreferences(defaults: defaults)
        let keyboard = preference.combination
        #expect(preference.mouseCombination == nil)
        preference.mouseCombination = MouseHotkeyCombination(button: 3, modifiers: [.shift])
        let reopened = HotkeyPreferences(defaults: defaults)
        #expect(reopened.mouseCombination == MouseHotkeyCombination(button: 3, modifiers: [.shift]))
        #expect(reopened.combination == keyboard)
        #expect(HotkeyPreferences(defaults: defaults, shortcut: .showCode).mouseCombination == nil)
        reopened.mouseCombination = nil
        #expect(preference.mouseCombination == nil)
        #expect(preference.combination == keyboard)
    }

    @Test func primaryButtonsNeedCommandOrOptionAndInvalidButtonsAreRejected() {
        #expect(!MouseHotkeyCombination(button: 0, modifiers: []).isValid)
        #expect(!MouseHotkeyCombination(button: 1, modifiers: [.control, .shift]).isValid)
        #expect(MouseHotkeyCombination(button: 0, modifiers: [.command]).isValid)
        #expect(MouseHotkeyCombination(button: 1, modifiers: [.option]).isValid)
        #expect(MouseHotkeyCombination(button: 2, modifiers: []).isValid)
        #expect(MouseHotkeyCombination(button: 4, modifiers: [.shift]).isValid)
        #expect(!MouseHotkeyCombination(button: -1, modifiers: [.option]).isValid)
        #expect(!MouseHotkeyCombination(button: 32, modifiers: []).isValid)
        #expect(!MouseHotkeyCombination(button: 3, modifiers: .init(rawValue: 1)).isValid)
    }

    @Test func invalidPersistedBindingIsIgnored() {
        let defaults = UserDefaults(suiteName: "MouseHotkeyTests.\(UUID().uuidString)")!
        let preference = HotkeyPreferences(defaults: defaults)
        preference.mouseCombination = MouseHotkeyCombination(button: 0, modifiers: [])
        #expect(preference.mouseCombination == nil)
    }
}

@Suite struct MouseShortcutRouterTests {
    @Test func exactMatchConsumesWholeClickAndFiresOnlyOnPress() {
        var router = MouseShortcutRouter()
        let registered = router.bind(.init(button: 3, modifiers: [.option]), to: .hint)
        #expect(registered)
        let missingModifier = router.handle(button: 3, modifiers: [], phase: .down, enabled: [.hint])
        #expect(missingModifier == .passThrough)
        let extraModifier = router.handle(button: 3, modifiers: [.option, .shift], phase: .down, enabled: [.hint])
        #expect(extraModifier == .passThrough)
        let press = router.handle(button: 3, modifiers: [.option], phase: .down, enabled: [.hint])
        #expect(press == .trigger(.hint))
        let repeatedPress = router.handle(button: 3, modifiers: [.option], phase: .down, enabled: [.hint])
        #expect(repeatedPress == .consume)
        router.bind(nil, to: .hint)
        let dragAfterClear = router.handle(button: 3, modifiers: [], phase: .drag, enabled: [])
        #expect(dragAfterClear == .consume)
        let releaseAfterClear = router.handle(button: 3, modifiers: [], phase: .up, enabled: [])
        #expect(releaseAfterClear == .consume)
        let unmatchedRelease = router.handle(button: 3, modifiers: [], phase: .up, enabled: [])
        #expect(unmatchedRelease == .passThrough)
    }

    @Test func disabledActionsAndUnmatchedReleasesPassThrough() {
        var router = MouseShortcutRouter()
        router.bind(.init(button: 2, modifiers: []), to: .nextDetail)
        let disabledPress = router.handle(button: 2, modifiers: [], phase: .down, enabled: [])
        #expect(disabledPress == .passThrough)
        let unmatchedRelease = router.handle(button: 2, modifiers: [], phase: .up, enabled: [.nextDetail])
        #expect(unmatchedRelease == .passThrough)
        let unmatchedDrag = router.handle(button: 2, modifiers: [], phase: .drag, enabled: [.nextDetail])
        #expect(unmatchedDrag == .passThrough)
    }

    @Test func interruptedEventStreamDoesNotSwallowTheNextOrdinaryClick() {
        var router = MouseShortcutRouter()
        router.bind(.init(button: 0, modifiers: [.option]), to: .hint)
        let press = router.handle(button: 0, modifiers: [.option], phase: .down, enabled: [.hint])
        #expect(press == .trigger(.hint))
        router.resetPressedButtons()
        let next = router.handle(button: 0, modifiers: [], phase: .down, enabled: [])
        #expect(next == .passThrough)
        let matching = router.handle(button: 0, modifiers: [.option], phase: .down, enabled: [.hint])
        #expect(matching == .trigger(.hint))
    }

    @Test func rejectedDuplicateKeepsPreviousBinding() {
        var router = MouseShortcutRouter()
        router.bind(.init(button: 2, modifiers: []), to: .hint)
        router.bind(.init(button: 3, modifiers: []), to: .showCode)
        let duplicateAccepted = router.bind(.init(button: 2, modifiers: []), to: .showCode)
        #expect(!duplicateAccepted)
        let invalidAccepted = router.bind(.init(button: 0, modifiers: []), to: .showCode)
        #expect(!invalidAccepted)
        let previousBinding = router.handle(button: 3, modifiers: [], phase: .down, enabled: [.showCode])
        #expect(previousBinding == .trigger(.showCode))
        let unchangedAccepted = router.bind(.init(button: 2, modifiers: []), to: .hint)
        #expect(unchangedAccepted)
    }
}
