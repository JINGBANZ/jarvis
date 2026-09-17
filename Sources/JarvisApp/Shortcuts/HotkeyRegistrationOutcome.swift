import Carbon.HIToolbox

enum HotkeyRegistrationOutcome: Equatable {
    case registered
    case failed(status: OSStatus)
}
