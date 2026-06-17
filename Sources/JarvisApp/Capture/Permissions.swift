import AVFoundation
import CoreGraphics
import AppKit
import JarvisCore

/// Requests the TCC permissions Jarvis needs **up front**, at launch, so the user grants them
/// once at the start rather than being surprised by a prompt mid-session. Each is only requested
/// when not already granted.
@MainActor
enum Permissions {
    static func primeAll() {
        requestMicrophone()
        requestScreenRecording()
    }

    /// Microphone — prompts on first launch; AVAudioEngine later just works.
    static func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            jlog("Jarvis: microphone permission already granted")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                jlog("Jarvis: microphone permission \(granted ? "granted" : "denied")")
            }
        case .denied, .restricted:
            jlog("Jarvis: microphone denied — enable in System Settings › Privacy & Security › Microphone")
        @unknown default:
            break
        }
    }

    /// Screen Recording — `CGRequestScreenCaptureAccess()` shows the prompt if undetermined.
    /// Note: macOS often requires a relaunch after the user enables it for the grant to take effect,
    /// which is exactly why we prompt at startup instead of lazily when `capture_screen` first fires.
    static func requestScreenRecording() {
        if CGPreflightScreenCaptureAccess() {
            jlog("Jarvis: screen recording permission already granted")
        } else {
            let granted = CGRequestScreenCaptureAccess()
            jlog("Jarvis: screen recording \(granted ? "granted" : "not yet granted — enable in System Settings › Privacy & Security › Screen Recording, then relaunch Jarvis")")
        }
    }

    /// True when both permissions are in place (used for a menu-bar status hint).
    static func allGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && CGPreflightScreenCaptureAccess()
    }
}
