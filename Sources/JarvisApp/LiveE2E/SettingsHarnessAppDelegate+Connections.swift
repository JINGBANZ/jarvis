#if JARVIS_LIVE_E2E
import AppKit
import JarvisBrainProviders
import JarvisCore
import JarvisOverlay

extension SettingsHarnessAppDelegate {
    func checkConnections(output: URL) throws {
        let store = FileSecretStore(directoryURL: output.appendingPathComponent("connections-secrets"))
        try require(store.setApiKey("settings-harness-example", for: .openAIAPIKey), "seed example key")
        let supervisor = LocalProxySupervisor(executable: nil, home: output.appendingPathComponent("connections-proxy"),
            launcher: AppProcessComposition.makeLauncher())
        var savedKey = false
        let section = ConnectionsSection(keyStore: store, signIns: SubscriptionSignIns(supervisor: supervisor),
            onKeySaved: { _, _ in savedKey = true }, onSubscriptionWillSignOut: { _ in })
        let page = section.makePage()
        page.onBack = {}
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.excludeFromScreenCapture()
        let background = SettingsBackgroundView(frame: NSRect(x: 0, y: 0, width: 820, height: 600))
        page.frame = background.bounds
        page.autoresizingMask = [.width, .height]
        background.addSubview(page)
        window.contentView = background
        defer { section.windowWillClose(); window.orderOut(nil) }

        let cards = descendants(page).compactMap { $0 as? SettingsCardView }
        func hasText(_ view: NSView, _ text: String) -> Bool {
            descendants(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == text }
        }
        guard cards.count == 2,
              let byok = cards.first(where: { hasText($0, "BYOK") }),
              let subscription = cards.first(where: { hasText($0, "SUBSCRIPTION") }) else {
            throw CocoaError(.coderValueNotFound)
        }
        try require(["OpenAI", "Gemini", "Deepgram"].allSatisfy { hasText(byok, $0) },
                    "BYOK contains the supported key providers")
        try require(["Codex", "Claude Code"].allSatisfy { hasText(subscription, $0) },
                    "Subscription contains both subscription providers")
        try require(hasText(page, "1 KEY SAVED"), "saved key count survives grouping")

        func button(_ identifier: String) throws -> NSButton {
            guard let button = descendants(page).compactMap({ $0 as? NSButton }).first(where: {
                $0.identifier?.rawValue == identifier
            }) else { throw CocoaError(.coderValueNotFound) }
            return button
        }
        let edit = try button("openAIAPIKey-action")
        try require(edit.title == "Edit" && button("geminiAPIKey-action").title == "Add API key",
                    "saved and empty credentials retain their actions")

        for size in [NSSize(width: 820, height: 600), NSSize(width: 560, height: 460)] {
            window.setContentSize(size)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                background.layoutSubtreeIfNeeded()
                try require(!byok.hasAmbiguousLayout && !subscription.hasAmbiguousLayout,
                            "connection groups have determinate layout")
                try snapshot(background, name: "connections-\(name)-\(Int(size.width))")
            }
            let collapsedHeight = byok.frame.height
            let providerRows = descendants(byok).compactMap { $0 as? SettingsRowView }
            try require(providerRows.count == 3, "each credential has a provider row")
            edit.performClick(nil)
            background.layoutSubtreeIfNeeded()
            try require(byok.frame.height > collapsedHeight, "inline editing expands the shared BYOK card")
            let visibleControls = descendants(byok).filter { !$0.isHiddenOrHasHiddenAncestor }
            guard let field = visibleControls.compactMap({ $0 as? NSSecureTextField }).first,
                  let cancel = visibleControls.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" }),
                  let save = visibleControls.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Save" })
            else { throw CocoaError(.coderValueNotFound) }
            let controlFrames = [field, cancel, save].map { $0.convert($0.bounds, to: byok) }
            try require(controlFrames.allSatisfy { byok.bounds.contains($0) },
                        "inline editor stays within the grouped card at both window sizes")
            try require(!controlFrames[0].intersects(controlFrames[1])
                        && !controlFrames[0].intersects(controlFrames[2]), "editor field does not overlap buttons")
            save.performClick(nil)
            try require(hasText(byok, "Enter a key first.") && !savedKey,
                        "empty save keeps the editor open and does not replace the existing key")
            try snapshot(background, name: "connections-editor-\(Int(size.width))")
            field.stringValue = "unsaved-example"
            cancel.performClick(nil)
            background.layoutSubtreeIfNeeded()
            try require(abs(byok.frame.height - collapsedHeight) < 1 && field.stringValue.isEmpty,
                        "cancelling clears input and restores the grouped card height")
            try require(store.apiKey(for: .openAIAPIKey) == "settings-harness-example" && !savedKey,
                        "editing and cancelling preserve the saved key")
        }
    }
}
#endif
