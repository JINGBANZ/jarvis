import AVFoundation
import Foundation

@MainActor
final class SyntheticAudioPlayer {
    enum Failure: Error, CustomStringConvertible {
        case preparationFailed(String)
        case playbackFailed(String)

        var description: String {
            switch self {
            case .preparationFailed(let name): "Could not prepare synthetic audio \(name)"
            case .playbackFailed(let name): "Could not play synthetic audio \(name)"
            }
        }
    }

    private var player: AVAudioPlayer?

    /// Preparing a player registers this process with Core Audio before the process-scoped tap is
    /// built. The same retained player is reused for the first playback when possible.
    func prepare(_ url: URL) throws {
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.prepareToPlay() else {
            throw Failure.preparationFailed(url.lastPathComponent)
        }
        self.player = player
    }

    @discardableResult
    func play(
        _ url: URL,
        abortingWhen isAborted: () -> Bool = { false }
    ) async throws -> (startedAt: TimeInterval, endedAt: TimeInterval) {
        let player: AVAudioPlayer
        if let prepared = self.player, prepared.url?.standardizedFileURL == url.standardizedFileURL {
            player = prepared
        } else {
            player = try AVAudioPlayer(contentsOf: url)
            guard player.prepareToPlay() else {
                throw Failure.preparationFailed(url.lastPathComponent)
            }
            self.player = player
        }
        let startedAt = Date().timeIntervalSince1970
        if isAborted() { throw CancellationError() }
        // ghost-mode-allowed: the explicit benchmark's process tap captures this fixed fixture while
        // muting its hardware output, so no autonomous sound reaches the operator.
        guard player.play() else { throw Failure.playbackFailed(url.lastPathComponent) }
        while player.isPlaying {
            if isAborted() {
                player.stop()
                throw CancellationError()
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        return (startedAt, Date().timeIntervalSince1970)
    }
}
