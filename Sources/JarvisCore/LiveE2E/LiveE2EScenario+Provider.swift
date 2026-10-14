#if JARVIS_LIVE_E2E
import Foundation

extension LiveE2EScenario {
    public func provider(atStep index: Int) -> BrainProvider {
        steps.prefix(index).reduce(brain.primary) { current, step in
            if case .switchBrain(let provider) = step { provider } else { current }
        }
    }

    public static func selectingProvider(
        _ provider: BrainProvider,
        in data: Data,
        fixturesDirectory: URL
    ) throws -> Data {
        // Validate before removing switches so an override cannot hide a malformed scenario.
        _ = try decode(data, fixturesDirectory: fixturesDirectory)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = json["steps"] as? [[String: Any]] else {
            throw Failure.invalid("expected a scenario object with steps")
        }
        json["brain"] = ["primary": provider.rawValue, "fallbacks": []] as [String: Any]
        json["steps"] = steps.filter { $0["switchBrain"] == nil }
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }
}
#endif
