/// User-visible lifecycle of one Realtime transcription socket. The mic-side state drives the
/// menu-bar health indicator; the system-audio side can degrade independently without stopping mic
/// coaching. Emitted by the OS-bound transcriber from any callback queue.
public enum RealtimeConnectionState: Sendable, Equatable {
    case connecting
    case ready
    case reconnecting(attempt: Int)
    case failed
    case stopped
}
