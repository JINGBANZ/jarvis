import Carbon.HIToolbox

/// Whether the most recent registration attempt for the currently-active combination succeeded.
/// Read by Settings to decide when a registration failure needs to be shown — only for a value the
/// user explicitly picked, never for the shipped default nobody chose.
enum HotkeyRegistrationOutcome: Equatable {
    case registered
    case failed(status: OSStatus)
}
