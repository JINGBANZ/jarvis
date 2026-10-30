#if JARVIS_LIVE_E2E
import AppKit
import Carbon.HIToolbox
import JarvisCore
import JarvisOverlay

@MainActor
final class ShortcutReplacementHarness: OverlayRendering {
    private let keyboard: HotkeyController
    private let mouse: MouseHotkeyController
    private let panel = OverlayBoxPanel()
    private let turns = TurnTaskBox()
    private var driver: CoachDriver?
    private var delivered: [String] = []
    private var progress: BrainReplyProgress?
    private var completed = false
    private static let actions: [CoachingShortcut] = [.hint, .explainMore, .showCode]

    init(defaults: UserDefaults) {
        let preferences = Self.actions.enumerated().map { index, shortcut in
            let preference = HotkeyPreferences(defaults: defaults, shortcut: shortcut)
            preference.combination = .init(keyCode: UInt32(18 + index), modifiers: [.command, .option, .control, .shift])
            preference.mouseCombination = .init(button: index + 2, modifiers: [.command, .option, .control, .shift])
            return preference
        }
        keyboard = HotkeyController(preferences: preferences)
        mouse = MouseHotkeyController(preferences: preferences)
        keyboard.onRequest = { [weak self] shortcut in
            guard let self, let driver = self.driver, let reason = shortcut.triggerReason else { return }
            self.turns.run {
                let outcome = await driver.handleTrigger(reason)
                if outcome == .spoke { await MainActor.run { self.completed = true } }
            }
        }
        mouse.isEnabled = { [weak self] _ in self?.driver != nil }
        mouse.onRequest = { [weak self] shortcut in self?.keyboard.onRequest?(shortcut) }
    }

    func run() async throws {
        defer {
            driver = nil
            turns.cancelAll()
            Self.actions.forEach { keyboard.unregister($0) }
            panel.setSessionLive(false)
        }
        try require(keyboard.registered.count == Self.actions.count, "keyboard registration")
        for mode: CoachingMode in [.automatic, .manual] {
            for (index, action) in Self.actions.enumerated() {
                for mouseFirst in [false, true] {
                    let brain = ShortcutReplacementBrain()
                    let transcript = RollingTranscript()
                    transcript.append(.init(speaker: .them, text: "Explain the binary search invariant.", at: 0))
                    let driver = CoachDriver(config: .default, transcript: transcript,
                        route: .init(targets: [.init(target: .init(provider: .openAI, modelID: "synthetic"), brain: brain)]),
                        screen: ShortcutReplacementScreen(), overlay: self, clock: SystemClock())
                    driver.setMode(mode)
                    self.driver = driver
                    delivered = []
                    progress = nil
                    completed = false
                    panel.setSessionLive(true)
                    try dispatch(action, mouse: mouseFirst)
                    try await wait { self.progress != nil }
                    let replacement = Self.actions[(index + 1) % Self.actions.count]
                    try dispatch(replacement, mouse: !mouseFirst)
                    try await wait { self.completed }
                    let calls = await brain.calls
                    try require(calls.count == 2 && delivered == ["replacement"] && progress == nil,
                                "only replacement delivers through keyboard and mouse in \(mode)")
                    let expected = replacement == .hint ? "hint shortcut" : replacement.title
                    try require(calls[1].compactMap(\.text).joined().contains(expected), "latest shortcut intent")
                    try require(driver.handledTranscriptCount == 1, "replacement commits unconsumed speech")
                    let pending = turns.cancelAll()
                    for task in pending { await task.value }
                    await driver.cancelBackgroundWork()?.value
                    panel.setSessionLive(false)
                }
            }
        }
        jlog("Signed shortcut replacement checks passed: keyboard/mouse dispatch, all coaching actions, automatic/manual")
    }

    private func dispatch(_ shortcut: CoachingShortcut, mouse useMouse: Bool) throws {
        if useMouse {
            let button = Int(shortcut.rawValue) + 1
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                mouseCursorPosition: .zero, mouseButton: .center) else { throw CocoaError(.coderValueNotFound) }
            event.flags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            try require(mouse.dispatchHarnessEvent(.otherMouseDown, event: event), "mouse down routes")
            try require(mouse.dispatchHarnessEvent(.otherMouseUp, event: event), "mouse up is consumed")
        } else {
            var event: EventRef?
            try require(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                0, EventAttributes(0), &event) == noErr, "create Carbon event")
            guard let event else { throw CocoaError(.coderValueNotFound) }
            defer { ReleaseEvent(event) }
            var identifier = EventHotKeyID(signature: 0x4A_52_56_53, id: shortcut.rawValue)
            try require(SetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr,
                "set Carbon identity")
            try require(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr, "Carbon dispatch")
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            try require(ContinuousClock.now < deadline, "shortcut replacement deadline")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "ShortcutReplacementHarness", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    nonisolated func render(_ hint: String) {}
    func deliver(_ hint: String, detail: ReplyDetail?) -> ReplyDetail? {
        delivered.append(hint)
        progress = nil
        return panel.deliver(hint, detail: detail)
    }
    func showReplyProgress(_ progress: BrainReplyProgress?) {
        self.progress = progress
        panel.showReplyProgress(progress)
    }
}

private actor ShortcutReplacementBrain: BrainClient {
    private(set) var calls: [[ChatMessage]] = []
    func makeConversation(progress: ToolCallProgressSink?) async throws -> any BrainConversation {
        Conversation(brain: self, progress: progress)
    }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        try await respond(messages, progress: nil)
    }
    private func respond(_ messages: [ChatMessage], progress: ToolCallProgressSink?) async throws -> BrainResponse {
        calls.append(messages)
        if calls.count == 1 {
            _ = progress?(.init(index: 0, name: "speak", arguments: #"{"hint":"unfinished"#))
            do { try await Task.sleep(for: .seconds(30)) }
            catch is CancellationError {}
            return .init(toolCalls: [.speak(callId: "old", hint: "superseded")])
        }
        return .init(toolCalls: [.speak(callId: "new", hint: "replacement")])
    }
    private struct Conversation: BrainConversation {
        let brain: ShortcutReplacementBrain
        let progress: ToolCallProgressSink?
        func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
            try await brain.respond(messages, progress: progress)
        }
        func finish() async {}
    }
}

private struct ShortcutReplacementScreen: ScreenCapturing {
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? { nil }
    func cancelCapture() {}
}
#endif
