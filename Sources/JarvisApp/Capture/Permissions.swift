import AVFoundation
import CoreGraphics
import AppKit
import JarvisCore

/// The macOS side of the TCC grants Jarvis needs: what it holds right now, and how to ask for one.
///
/// `PermissionGate` drives the asking at launch so a coaching session never has to,
/// and `JarvisReadiness` consumes `grantedReadinessPermissions` when the user presses Start. This
/// adapter only reports and requests; the Core reducer owns which permissions a configuration needs.
@MainActor
enum Permissions {
    /// What a probe in *this launch* established about System Audio Recording: granted, refused, or
    /// nil for never asked or asked and unable to run.
    ///
    /// Held in memory and never persisted. A stored answer reads exactly like a proved one, so a
    /// caller deciding whether a session can run cannot tell whether it holds evidence or a memory
    /// — and being wrong means a session that looks healthy while hearing nothing, because a refused
    /// tap still delivers frames.
    private(set) static var systemAudioProof: Bool?

    /// What macOS says about one grant right now. Microphone is a live read and Screen Recording is
    /// this process's preflight; System Audio Recording has neither, so it is whatever this launch
    /// proved.
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

    /// Content-free permission snapshot for `JarvisReadiness`.
    static func grantedReadinessPermissions() -> Set<JarvisReadiness.Permission> {
        Set(JarvisReadiness.Permission.allCases.filter(isGranted))
    }

    /// Asks macOS for one grant and reports what Jarvis holds afterwards. An already-granted
    /// permission returns immediately with no dialog, and macOS answers for a user who already
    /// refused without prompting again — so this is safe to call for any row.
    static func request(
        _ permission: JarvisReadiness.Permission,
        remembering preferences: PermissionPreferences
    ) async -> Bool {
        switch permission {
        case .microphone:
            return await requestMicrophone()
        case .systemAudio:
            // A probe that could not run proves nothing, so it leaves the answer unset rather than
            // claiming a refusal. Nothing falls back to a previous launch: unproved is unproved.
            systemAudioProof = await probeSystemAudio()
            return systemAudioProof == true
        case .screenRecording:
            // Recorded before the answer, because there won't be a usable one: this process cannot
            // see the grant either way. A later launch that still lacks it is the proof of refusal.
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

    /// `CGRequestScreenCaptureAccess()` shows the prompt when the grant is undetermined but never
    /// waits for an answer, and a grant made in System Settings is only visible to a new process.
    /// So `false` here means "not in this process yet", not "refused".
    private static func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            jlog("Jarvis: screen recording permission already granted")
            return true
        }
        let granted = CGRequestScreenCaptureAccess()
        jlog("Jarvis: screen recording \(granted ? "granted" : "not yet granted — enable in System Settings › Privacy & Security › Screen Recording, then relaunch Jarvis")")
        return granted
    }

    /// The probe blocks its thread while macOS shows the prompt, so it never runs on the main
    /// actor — the checklist has to keep drawing behind the dialog.
    private static func probeSystemAudio() async -> Bool? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: SystemAudioPermissionProbe.requestAccess())
            }
        }
    }
}
