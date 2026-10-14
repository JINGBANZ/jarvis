import Foundation

public struct BrainCacheObservation: Encodable, Equatable, Sendable {
    public let scope = "client_wire"
    public enum Segment: String, Encodable, Sendable {
        case model
        case instructions
        case tools
        case settings
        case input
    }

    public struct Usage: Encodable, Equatable, Sendable {
        public let totalInput: Int?
        public let cacheRead: Int?
        public let cacheWrite: Int?
        public let uncachedInput: Int?
        public let output: Int?

        public init(totalInput: Int?, cacheRead: Int?, cacheWrite: Int?, uncachedInput: Int?, output: Int?) {
            self.totalInput = totalInput
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.uncachedInput = uncachedInput
            self.output = output
        }

        enum CodingKeys: String, CodingKey {
            case totalInput = "total_input"
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
            case uncachedInput = "uncached_input"
            case output
        }
    }

    public let instructionsSHA256: String
    public let toolsSHA256: String
    public let settingsSHA256: String
    public let inputSHA256: String
    public let inputItemCount: Int
    public let previousInputItemCount: Int?
    public let inputPrefixPreserved: Bool?
    public let requestPrefixPreserved: Bool?
    public let firstChangedSegment: Segment?
    public let firstChangedInputIndex: Int?
    public let inputComparisonTruncated: Bool
    public let fingerprintLimit: Int
    public let usage: Usage?

    public init(
        instructionsSHA256: String,
        toolsSHA256: String,
        settingsSHA256: String,
        inputSHA256: String,
        inputItemCount: Int,
        previousInputItemCount: Int?,
        inputPrefixPreserved: Bool?,
        requestPrefixPreserved: Bool?,
        firstChangedSegment: Segment?,
        firstChangedInputIndex: Int?,
        inputComparisonTruncated: Bool,
        fingerprintLimit: Int,
        usage: Usage?
    ) {
        self.instructionsSHA256 = instructionsSHA256
        self.toolsSHA256 = toolsSHA256
        self.settingsSHA256 = settingsSHA256
        self.inputSHA256 = inputSHA256
        self.inputItemCount = inputItemCount
        self.previousInputItemCount = previousInputItemCount
        self.inputPrefixPreserved = inputPrefixPreserved
        self.requestPrefixPreserved = requestPrefixPreserved
        self.firstChangedSegment = firstChangedSegment
        self.firstChangedInputIndex = firstChangedInputIndex
        self.inputComparisonTruncated = inputComparisonTruncated
        self.fingerprintLimit = fingerprintLimit
        self.usage = usage
    }

    enum CodingKeys: String, CodingKey {
        case scope
        case instructionsSHA256 = "instructions_sha256"
        case toolsSHA256 = "tools_sha256"
        case settingsSHA256 = "settings_sha256"
        case inputSHA256 = "input_sha256"
        case inputItemCount = "input_item_count"
        case previousInputItemCount = "previous_input_item_count"
        case inputPrefixPreserved = "input_prefix_preserved"
        case requestPrefixPreserved = "request_prefix_preserved"
        case firstChangedSegment = "first_changed_segment"
        case firstChangedInputIndex = "first_changed_input_index"
        case inputComparisonTruncated = "input_comparison_truncated"
        case fingerprintLimit = "fingerprint_limit"
        case usage
    }
}
