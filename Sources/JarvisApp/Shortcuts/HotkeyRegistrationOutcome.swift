import Carbon.HIToolbox

/// The result of one `HotkeyController.apply(_:)` call. `HotkeySection.recorded(_:)` reads it to
/// flash immediate feedback after a rebind attempt; it is not retained as ongoing status — whether a
/// hotkey is live right now is `HotkeyController.registered != nil`.
enum HotkeyRegistrationOutcome: Equatable {
    case registered
    case failed(status: OSStatus)
}
