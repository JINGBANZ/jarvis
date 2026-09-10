import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct CodeSnippetRenderingTests {
    @MainActor @Test(arguments: ["'", "\""])
    func unmatchedQuotesDoNotColorAcrossLines(_ quote: String) throws {
        let snippet = try #require(CodeSnippet(language: "text", placement: "Current component",
            code: "prefix \(quote)a\nreturn value\nend \(quote)"))
        let text = CodeSnippetFormatting.render(snippet, fontSize: 16)
        let baseline = try #require(CodeSnippet(language: "text", placement: "Next step", code: "return value"))
        let expected = CodeSnippetFormatting.render(baseline, fontSize: 16)
        let keyword = (snippet.code as NSString).range(of: "return")
        #expect((text.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as? NSColor)
            == (expected.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor))
    }

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

    @MainActor @Test func codeDockCollapsesWithHeaderAndRestoresWithoutLosingSnippet() throws {
        let box = OverlayBoxPanel()
        box.setEnabled(true)
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        box.setCodeEnabled(true)
        let code = try #require(CodeSnippet(language: "Python", placement: "Start", code: "seen = {}"))
        #expect(box.deliverCodeSnippet(code) == code)
        box.clickCollapseButton()
        #expect(box.isCollapsed)
        #expect(box.currentCodeHeight == 0)
        box.clickCollapseButton()
        #expect(!box.isCollapsed)
        #expect(box.currentCodeHeight > 0)
        #expect(box.currentCodeSnippet == code)
    }

    @MainActor @Test func codeSettingControlsEmptyDockAndRejectsLateOutput() throws {
        let box = OverlayBoxPanel()
        box.setEnabled(true)
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        #expect(box.currentCodeHeight == 0)
        box.setCodeEnabled(true)
        #expect(box.currentCodeHeight > 0)
        #expect(box.currentCodeSnippet == nil)
        let code = try #require(CodeSnippet(language: "Python", placement: "Start", code: "seen = {}"))
        #expect(box.deliverCodeSnippet(code) == code)
        // Settings turns off the live code dock together with the master box.
        box.setEnabled(false)
        box.setCodeEnabled(false)
        box.setEnabled(true)
        #expect(box.deliverCodeSnippet(code) == nil)
        #expect(box.currentCodeHeight == 0)
        #expect(box.currentCodeSnippet == nil)
        box.setCodeEnabled(true)
        #expect(box.currentCodeSnippet == nil)
        #expect(box.currentCodeHeight > 0)
    }

    @MainActor @Test func codeAppearanceDoesNotInheritHistoryAppearance() throws {
        let previousWindows = Set(NSApplication.shared.windows.map(\.windowNumber))
        let box = OverlayBoxPanel()
        let window = try #require(NSApplication.shared.windows.first { !previousWindows.contains($0.windowNumber) })
        let content = try #require(window.contentView)
        let dock = try #require(content.subviews.compactMap { $0 as? CodeSnippetView }.first)
        box.setEnabled(true)
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        box.setCodeEnabled(true)
        box.setCodeFontSize(14)
        box.setCodeBackgroundOpacity(0.2)
        box.setFontSize(30)
        box.setOpacity(0.9)
        let snippet = try #require(CodeSnippet(language: "swift", placement: "Start", code: "return result"))
        #expect(box.deliverCodeSnippet(snippet) == snippet)
        let font = try #require(dock.codeText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 14)
        #expect(abs((dock.layer?.backgroundColor?.alpha ?? 0) - 0.2) < 0.001)
        #expect(content.layer?.backgroundColor == nil)
        #expect(abs(box.currentBoxOpacity - 0.9) < 0.001)
        box.setCodeBackgroundOpacity(0)
        #expect(dock.layer?.backgroundColor?.alpha == 0)
        #expect(dock.codeText.string == snippet.code)
    }

    @MainActor @Test func savedCodePreviewDoesNotChangeSessionAvailability() throws {
        let box = OverlayBoxPanel()
        box.setEnabled(true)
        box.setCodePreviewEnabled(true)
        box.showAppearancePreview(true)
        #expect(box.currentCodeSnippet != nil)
        box.setSessionLive(true)
        defer { box.setSessionLive(false); box.showAppearancePreview(false) }
        #expect(box.currentCodeHeight == 0)
        let snippet = try #require(CodeSnippet(language: "swift", placement: "Start", code: "return result"))
        #expect(box.deliverCodeSnippet(snippet) == nil)
        box.setCodeEnabled(true)
        #expect(box.deliverCodeSnippet(snippet) == snippet)
        box.setCodePreviewEnabled(false)
        #expect(box.currentCodeSnippet == snippet)
        box.setSessionLive(false)
        #expect(box.currentCodeHeight == 0)
    }

    @MainActor @Test func hintsPreserveCodeAndPreviewCannotReplaceLiveDelivery() throws {
        let box = OverlayBoxPanel()
        box.setEnabled(true)
        box.setCodeEnabled(true)
        let snippet = try #require(CodeSnippet(language: "swift", placement: "Inside solve", code: "  return value"))
        // Preview is only available while stopped; live delivery begins after it closes.
        box.showAppearancePreview(true)
        #expect(box.currentCodeSnippet != nil)
        box.showAppearancePreview(false)
        #expect(box.currentCodeSnippet == nil)
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        #expect(BroadcastOverlay([box]).deliverCodeSnippet(snippet) == snippet)
        _ = box.deliver(["Another hint"], perLineSeconds: [1], diagram: nil, explanation: nil)
        #expect(box.currentCodeSnippet == snippet)
        box.showAppearancePreview(true)
        #expect(box.currentCodeSnippet == snippet)
        box.showAppearancePreview(false)
        #expect(box.currentCodeSnippet == snippet)
        #expect(box.deliverCodeSnippet(nil) == nil)
        #expect(box.currentCodeSnippet == nil)
        #expect(box.deliverCodeSnippet(snippet) == snippet)
        box.setSessionLive(false)
        #expect(box.currentCodeSnippet == nil)
        box.setSessionLive(true)
        #expect(box.deliverCodeSnippet(snippet) == snippet)
        box.clear()
        #expect(box.currentCodeSnippet == nil)
    }

    @MainActor @Test func dockHeightIsBoundedAndDisabledBoxStaysHidden() throws {
        let box = OverlayBoxPanel(contentSize: NSSize(width: 320, height: 240))
        box.setCodeEnabled(true)
        box.setFontSize(32)
        let snippet = try #require(CodeSnippet(language: "python", placement: "Inside solve",
            code: "for item in items:\n    if item:\n        result.append(item)\nreturn result"))
        #expect(box.deliverCodeSnippet(snippet) == nil)
        #expect(!box.isPanelVisible)
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        #expect(box.deliverCodeSnippet(snippet) == nil)
        #expect(!box.isPanelVisible)
        box.setEnabled(true)
        #expect(box.isPanelVisible)
        #expect(box.deliverCodeSnippet(snippet) == snippet)
        #expect(box.currentCodeHeight > 0)
        #expect(box.currentCodeHeight <= 108)
        box.setEnabled(false)
        #expect(!box.isPanelVisible)
    }

    @MainActor @Test func minimumBoxKeepsCodeReadableAndPlacementScrollableWithoutTooltips() throws {
        let box = OverlayBoxPanel(contentSize: NSSize(width: 240, height: 140))
        box.setEnabled(true)
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        box.setCodeEnabled(true)
        let snippet = try #require(CodeSnippet(language: "swift",
            placement: "Inside solve, after collecting the current window and before updating the result with the next candidate", code: "return result"))
        #expect(box.deliverCodeSnippet(snippet) == snippet)
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

    @MainActor @Test func normalDockShowsThreeLinesWithoutScrollingAndDismissHasContrast() throws {
        let snippet = try #require(CodeSnippet(language: "swift", placement: "Inside solve",
            code: "let next = value + 1\nresult.append(next)\nreturn result"))
        let box = OverlayBoxPanel(contentSize: NSSize(width: 580, height: 420))
        box.setEnabled(true)
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        box.setCodeEnabled(true)
        box.setFontSize(18)
        #expect(box.deliverCodeSnippet(snippet) == snippet)
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
        // Code now uses a compact, fit-to-section size instead of mirroring the history font.
        #expect(font.pointSize >= 12)
        #expect(font.pointSize <= 18)
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
