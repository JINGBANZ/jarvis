import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite(.serialized) struct OverlayFormatPickerTests {
    @MainActor @Test func selectionClosesPickerBeforeNotifyingTheApp() {
        let box = OverlayBoxPanel()
        box.setInterviewFormat(.coding)
        var selections: [InterviewFormat?] = []
        box.onInterviewFormatSelected = { format in
            #expect(!box.isFormatPickerVisible)
            selections.append(format)
        }
        let windowsBeforeOpening = Set(NSApp.windows.map(ObjectIdentifier.init))
        box.clickFormatButton()
        #expect(box.isFormatPickerVisible)
        #expect(box.currentSharingType == .none)
        #expect(Set(NSApp.windows.map(ObjectIdentifier.init)) == windowsBeforeOpening,
                "Opening the picker must not create a separate, potentially capturable window")
        box.chooseInterviewFormat(.behavioral)
        #expect(selections == [.behavioral])
        #expect(box.currentSharingType == .none)
    }

    @MainActor @Test func openingFromCollapsedBoxCanBeCancelledWithoutChangingMode() {
        let box = OverlayBoxPanel()
        box.clickCollapseButton()
        box.clickFormatButton()
        #expect(!box.isCollapsed)
        #expect(box.isFormatPickerVisible)
        var didSelect = false
        box.onInterviewFormatSelected = { _ in didSelect = true }
        box.clickFormatButton()
        #expect(!box.isFormatPickerVisible)
        #expect(!didSelect)
    }

    @MainActor @Test func stoppingClosesAnOpenPicker() {
        let box = OverlayBoxPanel()
        box.clickFormatButton()
        #expect(box.isFormatPickerVisible)
        box.setSessionLive(false)
        #expect(!box.isFormatPickerVisible)
    }
}

@Test func modeReplacementClearsPausedCaptionAndQueuedTips() async {
    await checkCaptionReset()
}

@MainActor private func checkCaptionReset() async {
    let caption = OverlayCaptionPanel()
    caption.setEnabled(true)
    caption.render(["Old caption"], perLineSeconds: 60)
    for _ in 0..<100 where caption.currentText != "Old caption" {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(caption.currentText == "Old caption")
    caption.showAppearancePreview(true)
    caption.render(["Queued old caption"], perLineSeconds: 60)
    try? await Task.sleep(for: .milliseconds(20))
    caption.clear()
    caption.showAppearancePreview(false)
    #expect(!caption.isPanelVisible, "No previous caption may resume when Settings closes")
    caption.render(["New session"], perLineSeconds: 60)
    for _ in 0..<100 where caption.currentText != "New session" {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(caption.currentText == "New session", "Reset must preserve the enabled preference")
    caption.clear()
}
