import CryptoKit
import Foundation
import JarvisCore
import os

final class ProviderCacheObserver: BrainCacheObserving {
    static let fingerprintLimit = 256

    private struct Snapshot: Sendable {
        let model: String
        let instructions: String
        let tools: String
        let settings: String
        let input: String
        let inputCount: Int
        let items: [String]
    }

    private struct Checkpoints: Sendable {
        var initial: Snapshot?
        var latest: Snapshot?
        var attemptID: Int?
    }

    private let checkpoints = OSAllocatedUnfairLock(initialState: Checkpoints())

    func observe(request: Data, response: Data?, context: CoachingRequestContext?) -> BrainCacheObservation? {
        guard let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any] else {
            return nil
        }
        let reply = response.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let exchange = RecordedExchange.read(request: object, response: reply)
        let usage = exchange.usage.map {
            BrainCacheObservation.Usage(totalInput: $0.totalInput, cacheRead: $0.cacheRead,
                                        cacheWrite: $0.cacheWrite, uncachedInput: $0.uncachedInput,
                                        output: $0.output)
        }
        let modelDigest = Self.hash(object["model"] ?? NSNull())
        let instructions = object["instructions"] ?? object["system"] ?? object["system_instruction"] ?? NSNull()
        let instructionsDigest = Self.hash(instructions)
        let toolsDigest = Self.hash(object["tools"] ?? [])
        var settings = object.filter { !["model", "instructions", "system", "system_instruction", "tools", "input", "messages", "tool_choice"].contains($0.key) }
        if var config = settings["generation_config"] as? [String: Any] {
            config.removeValue(forKey: "tool_choice")
            settings["generation_config"] = config
        }
        let settingsDigest = Self.hash(settings)
        return checkpoints.withLock { checkpoints in
            let comparable: Snapshot?
            if context?.phase == .initial { comparable = checkpoints.initial }
            else if let context, context.attemptID == checkpoints.attemptID { comparable = checkpoints.latest }
            else { comparable = nil }
            var inputHash = SHA256()
            var prefixHash = SHA256()
            var items: [String] = []
            for (index, item) in exchange.inputFingerprints.enumerated() {
                let digest = SHA256.hash(data: Data(item.utf8))
                inputHash.update(data: Data(digest))
                if index < (comparable?.inputCount ?? 0) { prefixHash.update(data: Data(digest)) }
                if index < Self.fingerprintLimit { items.append(Self.hex(digest)) }
            }
            let snapshot = Snapshot(
                model: modelDigest, instructions: instructionsDigest, tools: toolsDigest,
                settings: settingsDigest, input: Self.hex(inputHash.finalize()),
                inputCount: exchange.inputFingerprints.count, items: items)
            let preserved = comparable.map {
                snapshot.inputCount >= $0.inputCount && Self.hex(prefixHash.finalize()) == $0.input
            }
            var firstChanged: BrainCacheObservation.Segment?
            var firstChangedInputIndex: Int?
            if let comparable {
                if snapshot.model != comparable.model { firstChanged = .model }
                else if snapshot.instructions != comparable.instructions { firstChanged = .instructions }
                else if snapshot.tools != comparable.tools { firstChanged = .tools }
                else if snapshot.settings != comparable.settings { firstChanged = .settings }
                else if preserved == false { firstChanged = .input }
                if preserved == false {
                    firstChangedInputIndex = comparable.items.indices.first {
                        $0 >= snapshot.items.count || comparable.items[$0] != snapshot.items[$0]
                    }
                }
            }
            if let context {
                if context.phase == .initial { checkpoints.initial = snapshot }
                checkpoints.latest = snapshot
                checkpoints.attemptID = context.attemptID
            }
            return BrainCacheObservation(
                instructionsSHA256: snapshot.instructions, toolsSHA256: snapshot.tools,
                settingsSHA256: snapshot.settings, inputSHA256: snapshot.input,
                inputItemCount: snapshot.inputCount, previousInputItemCount: comparable?.inputCount,
                inputPrefixPreserved: preserved,
                requestPrefixPreserved: comparable.map { _ in firstChanged == nil },
                firstChangedSegment: firstChanged, firstChangedInputIndex: firstChangedInputIndex,
                inputComparisonTruncated: preserved == false && firstChangedInputIndex == nil,
                fingerprintLimit: Self.fingerprintLimit, usage: usage)
        }
    }

    private static func hash(_ value: Any) -> String {
        hex(SHA256.hash(data: Data(RecordedExchange.canonical(value).utf8)))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
