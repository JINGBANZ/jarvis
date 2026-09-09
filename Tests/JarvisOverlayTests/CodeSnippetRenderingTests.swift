import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct CodeSnippetRenderingTests {
    @MainActor @Test func deliveryAcceptsOnlyVisibleCodeAndExplanation() throws {
        let box = OverlayBoxPanel()
        let sink = BroadcastOverlay([box])
        box.setCodeEnabled(true)
        let snippet = try #require(CodeSnippet(language: "python", placement: "Start", code: "seen = {}"))
        #expect(sink.deliverCodeSnippet(snippet) == nil)
        #expect(sink.deliver(["Initialize"], perLineSeconds: [1], diagram: nil, explanation: "Keep state") == nil)
        box.setEnabled(true)
        box.setSessionLive(true)
        #expect(sink.deliverCodeSnippet(snippet) == snippet)
        #expect(box.currentCodeSnippet == snippet)
        #expect(sink.deliver(["Initialize"], perLineSeconds: [1], diagram: nil, explanation: "Keep state") == "Keep state")
        box.setEnabled(false)
        #expect(sink.deliverCodeSnippet(snippet) == nil)
        #expect(box.currentCodeSnippet == nil)
        #expect(sink.deliver(["Initialize"], perLineSeconds: [1], diagram: nil, explanation: "Keep state") == nil)
        box.setSessionLive(false)
    }

    @MainActor @Test func codeDockCollapsesWithHeaderAndRestoresWithoutLosingSnippet() async throws {
        let box = OverlayBoxPanel()
        box.setCodeEnabled(true)
        let code = try #require(CodeSnippet(language: "Python", placement: "Start", code: "seen = {}"))
        box.showCodeSnippet(code)
        for _ in 0..<100 where box.currentCodeSnippet != code { try await Task.sleep(for: .milliseconds(10)) }
        box.clickCollapseButton()
        #expect(box.isCollapsed)
        #expect(box.currentCodeHeight == 0)
        box.clickCollapseButton()
        #expect(!box.isCollapsed)
        #expect(box.currentCodeHeight > 0)
        #expect(box.currentCodeSnippet == code)
    }

    @MainActor @Test func codeSettingControlsEmptyDockAndRejectsLateOutput() async throws {
        let box = OverlayBoxPanel()
        #expect(box.currentCodeHeight == 0)
        box.setCodeEnabled(true)
        #expect(box.currentCodeHeight > 0)
        #expect(box.currentCodeSnippet == nil)
        let code = try #require(CodeSnippet(language: "Python", placement: "Start", code: "seen = {}"))
        box.showCodeSnippet(code)
        box.setCodeEnabled(false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(box.currentCodeHeight == 0)
        #expect(box.currentCodeSnippet == nil)
        box.showAppearancePreview(true)
        #expect(box.currentCodeHeight == 0)
        box.showAppearancePreview(false)
        box.setCodeEnabled(true)
        #expect(box.currentCodeSnippet == nil)
        #expect(box.currentCodeHeight > 0)
    }

    @MainActor @Test func hintsDoNotReplaceCodeAndPreviewRestoresUntilClearOrStop() async throws {
        let box = OverlayBoxPanel()
        box.setCodeEnabled(true)
        let snippet = try #require(CodeSnippet(language: "swift", placement: "Inside solve", code: "  return value"))
        BroadcastOverlay([box]).showCodeSnippet(snippet)
        for _ in 0..<100 where box.currentCodeSnippet != snippet { try await Task.sleep(for: .milliseconds(10)) }
        #expect(box.currentCodeSnippet == snippet)
        box.render(["Another hint"], perLineSeconds: [1])
        for _ in 0..<100 where box.entryCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(box.currentCodeSnippet == snippet)
        box.showAppearancePreview(true)
        #expect(box.currentCodeSnippet != snippet)
        box.showAppearancePreview(false)
        #expect(box.currentCodeSnippet == snippet)
        box.showCodeSnippet(nil)
        for _ in 0..<100 where box.currentCodeSnippet != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(box.currentCodeSnippet == nil)
        box.showCodeSnippet(snippet)
        for _ in 0..<100 where box.currentCodeSnippet == nil { try await Task.sleep(for: .milliseconds(10)) }
        box.showAppearancePreview(true)
        box.setSessionLive(false)
        box.showAppearancePreview(false)
        #expect(box.currentCodeSnippet == nil)
        box.showCodeSnippet(snippet)
        for _ in 0..<100 where box.currentCodeSnippet == nil { try await Task.sleep(for: .milliseconds(10)) }
        box.clear()
        #expect(box.currentCodeSnippet == nil)
    }

    @MainActor @Test func dockHeightIsBoundedAndDisabledBoxStaysHidden() async throws {
        let box = OverlayBoxPanel(contentSize: NSSize(width: 320, height: 240))
        box.setCodeEnabled(true)
        box.setFontSize(32)
        let snippet = try #require(CodeSnippet(language: "python", placement: "Inside solve",
            code: "for item in items:\n    if item:\n        result.append(item)\nreturn result"))
        box.showCodeSnippet(snippet)
        for _ in 0..<100 where box.currentCodeSnippet == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(box.currentCodeHeight > 0)
        #expect(box.currentCodeHeight <= 108)
        #expect(!box.isPanelVisible)
        box.setSessionLive(true)
        #expect(!box.isPanelVisible)
        box.setEnabled(true)
        #expect(box.isPanelVisible)
        box.setEnabled(false)
        #expect(!box.isPanelVisible)
        box.setSessionLive(false)
    }

    @MainActor @Test func minimumBoxKeepsCodeReadableAndPlacementScrollableWithoutTooltips() async throws {
        let box = OverlayBoxPanel(contentSize: NSSize(width: 240, height: 140))
        box.setCodeEnabled(true)
        let snippet = try #require(CodeSnippet(language: "swift",
            placement: "Inside solve, after collecting the current window and before updating the result with the next candidate", code: "return result"))
        box.showCodeSnippet(snippet)
        for _ in 0..<100 where box.currentCodeSnippet == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(box.currentCodeHeight >= 70)
        #expect(box.currentContentSize.height - box.currentCodeHeight - box.currentHeaderHeight >= 44)
        let dock = CodeSnippetView(frame: NSRect(x: 0, y: 0, width: 240, height: 96))
        dock.show(snippet, fontSize: 24)
        dock.layoutSubtreeIfNeeded()
        let scroll = try #require(dock.subviews.compactMap { $0 as? NSScrollView }.first)
        #expect(scroll.contentSize.height >= 64)
        let document = try #require(scroll.documentView)
        let placement = try #require(document.subviews.compactMap { $0 as? NSTextField }.first)
        #expect(placement.stringValue == snippet.placement)
        #expect(placement.frame.height > 18)
        #expect(placement.toolTip == nil)
        #expect(document.frame.height > scroll.contentSize.height)
    }

    @MainActor @Test func normalDockShowsThreeLinesWithoutScrollingAndDismissHasContrast() async throws {
        let snippet = try #require(CodeSnippet(language: "swift", placement: "Inside solve",
            code: "let next = value + 1\nresult.append(next)\nreturn result"))
        let box = OverlayBoxPanel(contentSize: NSSize(width: 580, height: 420))
        box.setCodeEnabled(true)
        box.setFontSize(18)
        box.showCodeSnippet(snippet)
        for _ in 0..<100 where box.currentCodeSnippet == nil { try await Task.sleep(for: .milliseconds(10)) }
        let dock = CodeSnippetView(frame: NSRect(x: 0, y: 0, width: 580, height: box.currentCodeHeight))
        dock.show(snippet, fontSize: 18)
        dock.layoutSubtreeIfNeeded()
        let scroll = try #require(dock.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        #expect(document.frame.height <= scroll.contentSize.height)
        let foreground = try #require(dock.dismissButton.attributedTitle.attribute(
            .foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect((luminance(foreground) + 0.05) / (luminance(CodeSnippetView.background) + 0.05) >= 4.5)
    }

    @MainActor @Test func syntaxForegroundMeetsContrastOnCodeAndCorrectionBackgrounds() throws {
        let snippet = try #require(CodeSnippet(language: "swift", placement: "Inside solve",
            code: "let n = 42 // count\nreturn \"value\"", highlightedLines: [1, 2]))
        let text = CodeSnippetFormatting.render(snippet, fontSize: 16)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
            let foreground = attributes[.foregroundColor] as! NSColor
            let background = attributes[.backgroundColor] as? NSColor ?? CodeSnippetView.background
            let ratio = (luminance(foreground) + 0.05) / (luminance(background) + 0.05)
            #expect(ratio >= 4.5)
        }
    }

    @MainActor @Test func codeFitsSeparateAreaAndRetainsOpaqueReadableFormatting() throws {
        let snippet = try #require(CodeSnippet(language: "swift", placement: "Inside solve", code: "  let value = 1\n  return value", highlightedLines: [2]))
        let dock = CodeSnippetView(frame: NSRect(x: 0, y: 0, width: 300, height: 130))
        dock.show(snippet, fontSize: 24)
        #expect(dock.codeText.string == snippet.code)
        #expect(dock.layer?.backgroundColor?.alpha == 1)
        let font = try #require(dock.codeText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 24)
        #expect(font.isFixedPitch)
        #expect(dock.codeText.attribute(.backgroundColor, at: 18, effectiveRange: nil) != nil)
        var dismissed = false
        dock.onDismiss = { dismissed = true }
        dock.dismissButton.performClick(nil)
        #expect(dismissed)
    }
}

private func luminance(_ color: NSColor) -> CGFloat {
    let rgb = color.usingColorSpace(.sRGB)!
    func linear(_ component: CGFloat) -> CGFloat {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
        + 0.0722 * linear(rgb.blueComponent)
}
