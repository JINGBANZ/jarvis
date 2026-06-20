import Foundation

/// How aggressively the Realtime session should de-noise the input *before* VAD, and how that choice
/// is made. `near_field` suits a close mic (headset/AirPods); `far_field` suits a distant mic
/// (built-in laptop / monitor / room). `.auto` derives the profile from the detected mic — the OS
/// classification lives in `JarvisApp` (`InputDeviceProximity`); the policy below stays Foundation-only
/// and unit-tested. See `RealtimeSession.sessionUpdate`.
public enum NoiseReduction {
    /// Resolve the wire value (`"near_field"` / `"far_field"` / nil-to-omit) for a mode. `micProximity`
    /// is consulted only for `.auto`; pinned modes ignore it. Unknown proximity falls back to
    /// `far_field`: it is the gentler profile, so it won't over-suppress a quiet or distant voice when
    /// we can't tell what the device is.
    public static func profile(mode: NoiseReductionMode, micProximity: MicProximity) -> String? {
        switch mode {
        case .off: return nil
        case .nearField: return "near_field"
        case .farField: return "far_field"
        case .auto:
            switch micProximity {
            case .near: return "near_field"
            case .far, .unknown: return "far_field"
            }
        }
    }
}

/// The noise-reduction policy: auto-detect from the mic, pin a profile, or disable.
public enum NoiseReductionMode: Sendable, Equatable {
    case auto
    case nearField
    case farField
    case off
}

/// How close the active input mic sits to the speaker — the abstract signal `.auto` resolves on.
/// `JarvisApp` maps a Core Audio transport type onto this; Core only reasons about the abstraction.
public enum MicProximity: Sendable, Equatable {
    case near       // headset / earbuds / AirPods / USB close mic
    case far        // built-in laptop, monitor, room, or remote (AirPlay/HDMI) mic
    case unknown    // aggregate / virtual / undetectable
}
