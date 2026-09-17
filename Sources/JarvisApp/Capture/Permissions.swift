import AVFoundation
import CoreGraphics
import AppKit
import JarvisCore

/// Design: wiki/architecture.md#permissions
@MainActor
enum Permissions {
    /// Proved in this launch only; nil means never asked or the probe could not run. Never persist
    /// it: a stored answer reads like proof, and a refused tap still delivers frames.
    private(set) static var systemAudioProof: Bool?

    static func isGranted(_ permission: JarvisReadiness.Permission) -> Bool {
        switch permission {
        case .microphone:
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .systemAudio:
            systemAudioProof == true
        case .screenRecording:
            CGPreflightScreenCaptureAccess()
        }
    }

    static func grantedReadinessPermissions() -> Set<JarvisReadiness.Permission> {
        Set(JarvisReadiness.Permission.allCases.filter(isGranted))
    }

    /// Safe for any row: a held grant returns at once, and macOS answers past refusals silently.
    static func request(
        _ permission: JarvisReadiness.Permission,
        remembering preferences: PermissionPreferences
    ) async -> Bool {
        switch permission {
        case .microphone:
            return await requestMicrophone()
        case .systemAudio:
            systemAudioProof = await probeSystemAudio()
            return systemAudioProof == true
        case .screenRecording:
            // Recorded before asking: this process can't see the answer, so a later launch that
            // still lacks the grant is the proof of refusal.
            preferences.screenRecordingAsked = true
            return requestScreenRecording()
        }
    }

    private static func requestMicrophone() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            jlog("Jarvis: microphone permission already granted")
            return true
        }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        jlog("Jarvis: microphone permission \(granted ? "granted" : "denied")")
        return granted
    }

    /// `CGRequestScreenCaptureAccess()` never waits for an answer, and a new grant is visible only
    /// to a new process. So `false` means "not in this process yet", not "refused".
    private static func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            jlog("Jarvis: screen recording permission already granted")
            return true
        }
        let granted = CGRequestScreenCaptureAccess()
        jlog("Jarvis: screen recording \(granted ? "granted" : "not yet granted — enable in System Settings › Privacy & Security › Screen Recording, then relaunch Jarvis")")
        return granted
    }

    /// Off the main actor: the probe blocks during the prompt, and the checklist must keep drawing.
    private static func probeSystemAudio() async -> Bool? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: SystemAudioPermissionProbe.requestAccess())
            }
        }
    }
}
