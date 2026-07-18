import Foundation

/// Correlates content-free local PCM activity episodes with server VAD intervals.
///
/// `AudioContinuityWitness` owns capture/delivery/socket accounting; this focused value owns the
/// independent matching state. Callers provide serialized access, so it needs no lock of its own.
struct AudioContinuityMatcher {
    struct Observation {
        let sampleCount: Int
        let anomalies: [AudioContinuityWitness.Anomaly]
    }

    private enum LocalActivityState {
        case pending
        case matched
        case warned
    }

    private struct LocalActivityEpisode {
        let startedAt: TimeInterval
        var lastActiveAt: TimeInterval
        var state: LocalActivityState
    }

    private let configuration: AudioContinuityWitness.Configuration
    private var activityDetector: AdaptiveAudioActivityDetector
    private var localActivityEpisodes: [LocalActivityEpisode] = []
    private var localActivityOpen = false
    private var activeServerSpeechItemID: String?
    private var activeServerSpeechStartedAt: TimeInterval?

    init(configuration: AudioContinuityWitness.Configuration) {
        self.configuration = configuration
        activityDetector = AdaptiveAudioActivityDetector(configuration: configuration.activity)
    }

    var isActive: Bool { activityDetector.isActive }
    var activeSince: TimeInterval? {
        localActivityOpen ? localActivityEpisodes.last?.startedAt : nil
    }
    var lastActivityAt: TimeInterval? {
        localActivityOpen ? localActivityEpisodes.last?.lastActiveAt : nil
    }

    mutating func recordDelivery(pcm16: Data, at timestamp: TimeInterval) -> Observation {
        let activity = activityDetector.observe(pcm16: pcm16)
        let anomalies = updateLocalActivity(isActive: activity.isActive, at: timestamp)
        return Observation(sampleCount: activity.sampleCount, anomalies: anomalies)
    }

    mutating func selectNewSocketGeneration() {
        activeServerSpeechItemID = nil
        activeServerSpeechStartedAt = nil
    }

    mutating func recordServerSpeech(
        _ signal: AudioContinuityWitness.ServerSpeechSignal,
        itemID: String?, sessionAudioTime: TimeInterval?, observedAt: TimeInterval
    ) -> [AudioContinuityWitness.Anomaly] {
        switch signal {
        case .speechStarted:
            activeServerSpeechItemID = itemID
            activeServerSpeechStartedAt = sessionAudioTime
            guard let sessionAudioTime else { return [] }
            return matchServerStart(sessionAudioTime, observedAt: observedAt)
        case .speechStopped:
            guard activeServerSpeechItemID == nil || itemID == nil
                    || activeServerSpeechItemID == itemID else { return [] }
            var anomalies: [AudioContinuityWitness.Anomaly] = []
            if let start = activeServerSpeechStartedAt, let end = sessionAudioTime {
                anomalies = matchServerInterval(start: start, end: end, observedAt: observedAt)
            }
            closeServerSpeech()
            return anomalies
        case .transcriptionCompleted, .transcriptionFailed:
            // A terminal event is the server's final lifecycle boundary when speech_stopped is lost
            // or malformed. Item identity prevents a late terminal for an older item from closing a
            // newer active utterance.
            if let itemID, itemID == activeServerSpeechItemID {
                closeServerSpeech()
            }
            return []
        case .transcriptionDelta:
            return []
        }
    }

    mutating func poll(at timestamp: TimeInterval) -> [AudioContinuityWitness.Anomaly] {
        var anomalies: [AudioContinuityWitness.Anomaly] = []
        for index in localActivityEpisodes.indices
            where localActivityEpisodes[index].state == .pending {
            let episode = localActivityEpisodes[index]
            let duration = max(0, timestamp - episode.startedAt)
            let observedActivityDuration = max(0, episode.lastActiveAt - episode.startedAt)
            if observedActivityDuration >= configuration.sustainedActivityDuration,
               timestamp - episode.lastActiveAt >= configuration.serverSpeechGrace {
                anomalies.append(.localActivityUnmatched(activeSince: episode.startedAt,
                                                         duration: duration))
                localActivityEpisodes[index].state = .warned
            }
        }
        return anomalies
    }

    private mutating func updateLocalActivity(
        isActive: Bool, at timestamp: TimeInterval
    ) -> [AudioContinuityWitness.Anomaly] {
        if isActive {
            if localActivityOpen, let lastActiveAt = localActivityEpisodes.last?.lastActiveAt,
               timestamp - lastActiveAt > configuration.activityHangover {
                localActivityOpen = false
            }
            if localActivityOpen {
                localActivityEpisodes[localActivityEpisodes.count - 1].lastActiveAt = timestamp
            } else {
                localActivityEpisodes.append(.init(startedAt: timestamp, lastActiveAt: timestamp,
                                                   state: .pending))
                localActivityOpen = true
                trimEpisodes()
            }
            if let start = activeServerSpeechStartedAt {
                return matchServerInterval(start: start, end: timestamp, observedAt: timestamp)
            }
        } else if localActivityOpen,
                  let lastActiveAt = localActivityEpisodes.last?.lastActiveAt,
                  timestamp - lastActiveAt >= configuration.activityHangover {
            localActivityOpen = false
        }
        return []
    }

    private mutating func closeServerSpeech() {
        activeServerSpeechItemID = nil
        activeServerSpeechStartedAt = nil
    }

    private mutating func matchServerStart(
        _ serverStart: TimeInterval, observedAt: TimeInterval
    ) -> [AudioContinuityWitness.Anomaly] {
        let tolerance = configuration.activityHangover
        return matchLocalActivity(where: { episode in
            serverStart >= episode.startedAt - tolerance
                && serverStart <= episode.lastActiveAt + tolerance
        }, observedAt: observedAt)
    }

    private mutating func matchServerInterval(
        start: TimeInterval, end: TimeInterval, observedAt: TimeInterval
    ) -> [AudioContinuityWitness.Anomaly] {
        let tolerance = configuration.activityHangover
        return matchLocalActivity(where: { episode in
            episode.startedAt <= end + tolerance
                && start <= episode.lastActiveAt + tolerance
        }, observedAt: observedAt)
    }

    private mutating func matchLocalActivity(
        where overlaps: (LocalActivityEpisode) -> Bool, observedAt: TimeInterval
    ) -> [AudioContinuityWitness.Anomaly] {
        var anomalies: [AudioContinuityWitness.Anomaly] = []
        for index in localActivityEpisodes.indices where overlaps(localActivityEpisodes[index]) {
            if localActivityEpisodes[index].state == .warned {
                anomalies.append(.serverSpeechObservedAfterUnmatchedActivity(
                    activeSince: localActivityEpisodes[index].startedAt,
                    serverObservedAt: observedAt))
            }
            localActivityEpisodes[index].state = .matched
        }
        return anomalies
    }

    private mutating func trimEpisodes() {
        let overflow = localActivityEpisodes.count - configuration.maximumActivityEpisodes
        if overflow > 0 { localActivityEpisodes.removeFirst(overflow) }
    }
}
